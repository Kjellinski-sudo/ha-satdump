#!/usr/bin/env python3
"""Papierkorb-Weiche: nginx schickt nur die Lösch-Anfragen des Datei-Managers hierher.

Statt endgültig zu löschen, wird mit den Rechten des angemeldeten Benutzers in den Ordner
/Papierkorb derselben Quelle (Stick bzw. Stick 2) verschoben (Quantum: PATCH /api/resources, action "move").
Was schon im Papierkorb liegt, wird wirklich gelöscht (Anfrage geht unverändert an Quantum).
Schlägt das Verschieben fehl, wird NICHT gelöscht, der Eintrag kommt als "failed" zurück.
Außerdem: POST /dateien-api/wiederherstellen legt Einträge an ihren alten Platz zurück.
"""
import http.client
import json
import os
import posixpath
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlencode, urlsplit

try:
    import fcntl
except ImportError:  # nur zum Testen unter Windows
    fcntl = None

QUANTUM_HOST = "127.0.0.1"
QUANTUM_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8081
LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8082
KORB = "/Papierkorb"
SPERRE = os.environ.get("DATEIEN_SPERRE", "/tmp/gaeste.lock")
# Hauptbenutzer (nur für Gäste mit Löschrecht, die den Papierkorb selbst nicht sehen)
ADMIN_NAME = os.environ.get("DATEIEN_ADMIN_USER", "")
ADMIN_PW = os.environ.get("DATEIEN_ADMIN_PW", "")
WEITERGEBEN = ("Authorization", "Cookie", "X-Forwarded-For", "X-Real-IP", "X-Forwarded-Proto", "X-Forwarded-Host", "User-Agent")


def quellen_laden():
    """Quelle -> {pfad, herkunft}; aus /tmp/quellen.json (von run.sh geschrieben)."""
    try:
        with open(os.environ.get("DATEIEN_QUELLEN", "/tmp/quellen.json"), encoding="utf-8") as f:
            return {q["name"]: q for q in json.load(f)}
    except (OSError, ValueError, KeyError, TypeError):
        return {"Stick": {"name": "Stick", "pfad": os.environ.get("DATEIEN_STICK", "/mnt/stick"),
                          "herkunft": os.environ.get("DATEIEN_HERKUNFT", "/data/papierkorb_herkunft.json")}}


QUELLEN = quellen_laden()


def freier_name(wurzel, ordner, name):
    """Freier Name im Ordner (Pfad auf dem Stick), bei Gleichstand „name (1).ext“."""
    stamm, endung = os.path.splitext(name) if not name.startswith(".") else (name, "")
    kandidat, n = name, 0
    while os.path.lexists(os.path.join(wurzel, ordner.strip("/"), kandidat)):
        n += 1
        kandidat = f"{stamm} ({n}){endung}"
    return kandidat


def herkunft_lesen(quelle):
    try:
        with open(quelle["herkunft"], encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def herkunft_aendern(quelle, name_im_korb, pfad=None):
    """pfad=None: Eintrag vergessen, sonst Herkunft merken."""
    with open(SPERRE, "a") as sperre:
        if fcntl:
            fcntl.flock(sperre, fcntl.LOCK_EX)
        daten = herkunft_lesen(quelle)
        if pfad is None:
            daten.pop(name_im_korb, None)
        else:
            daten[name_im_korb] = {"pfad": "/" + pfad.strip("/"), "zeit": int(time.time())}
        with open(quelle["herkunft"] + ".neu", "w", encoding="utf-8") as f:
            json.dump(daten, f, ensure_ascii=False)
        os.replace(quelle["herkunft"] + ".neu", quelle["herkunft"])


def im_korb(pfad):
    p = "/" + pfad.strip("/")
    return p == KORB or p.startswith(KORB + "/")


class Weiche(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass  # keine Pfade/Benutzer doppelt ins Protokoll; Quantum protokolliert selbst

    def _quantum(self, methode, pfad, body=None):
        kopf = {k: self.headers[k] for k in WEITERGEBEN if self.headers.get(k)}
        if body is not None:
            kopf["Content-Type"] = "application/json"
        con = http.client.HTTPConnection(QUANTUM_HOST, QUANTUM_PORT, timeout=120)
        try:
            con.request(methode, pfad, body=body, headers=kopf)
            antwort = con.getresponse()
            return antwort.status, antwort.read(), antwort.getheader("Content-Type", "application/json")
        finally:
            con.close()

    def _senden(self, status, daten, typ="application/json"):
        if isinstance(daten, (dict, list)):
            daten = json.dumps(daten).encode()
        self.send_response(status)
        self.send_header("Content-Type", typ)
        self.send_header("Content-Length", str(len(daten)))
        self.end_headers()
        self.wfile.write(daten)

    def _move(self, source, von, nach):
        anfrage = {"action": "move", "rename": False, "overwrite": False, "items": [
            {"fromSource": source, "fromPath": von, "toSource": source, "toPath": nach}]}
        status, antwort, _ = self._quantum("PATCH", "/api/resources", json.dumps(anfrage).encode())
        try:
            misslungen = bool(json.loads(antwort or b"{}").get("failed"))
        except ValueError:
            misslungen = False
        return status, status in (200, 204) and not misslungen

    def _gast_verschieben(self, source, pfad, ziel):
        """Gäste sehen den Papierkorb nicht. Hat der Gast Löschrecht und sieht er den Eintrag, verschiebt die App
        ihn mit dem Hauptbenutzer in den Papierkorb (Pfad des Gastes relativ zu seinem Startordner)."""
        status, antwort, _ = self._quantum("GET", "/api/users?username=self")
        if status != 200:
            return status, False
        try:
            ich = json.loads(antwort)
            scope = next(s for s in ich.get("scopes", []) if s.get("name") == source)
        except (ValueError, StopIteration, AttributeError):
            return 403, False
        if not (scope.get("permissions") or {}).get("delete"):
            return 403, False
        status, _, _ = self._quantum("GET", "/api/resources?" + urlencode({"path": pfad, "source": source}))
        if status != 200:
            return 403, False
        absolut = posixpath.join("/" + (scope.get("scope") or "/").strip("/"), pfad.lstrip("/"))
        if im_korb(absolut) or not ADMIN_NAME:
            return 403, False
        con = http.client.HTTPConnection(QUANTUM_HOST, QUANTUM_PORT, timeout=30)
        try:
            con.request("POST", "/api/auth/login?" + urlencode({"username": ADMIN_NAME}), headers={"X-Password": quote(ADMIN_PW, safe="")})
            antwort = con.getresponse()
            token = antwort.read().decode()
            if antwort.status != 200:
                return antwort.status, False
        finally:
            con.close()
        anfrage = {"action": "move", "rename": False, "overwrite": False, "items": [
            {"fromSource": source, "fromPath": absolut, "toSource": source, "toPath": ziel}]}
        con = http.client.HTTPConnection(QUANTUM_HOST, QUANTUM_PORT, timeout=120)
        try:
            con.request("PATCH", "/api/resources", body=json.dumps(anfrage).encode(),
                        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
            antwort = con.getresponse()
            inhalt = antwort.read()
            try:
                misslungen = bool(json.loads(inhalt or b"{}").get("failed"))
            except ValueError:
                misslungen = False
            return antwort.status, antwort.status in (200, 204) and not misslungen, absolut
        finally:
            con.close()

    def _verschieben(self, eintraege):
        """eintraege: [(source, path)] -> (succeeded, failed) im Format von BulkDeleteResponse"""
        ok, fehler = [], []
        for source, pfad in eintraege:
            quelle = QUELLEN.get(source)
            if not quelle:
                fehler.append({"source": source, "path": pfad, "message": "unbekannter Speicher"})
                continue
            name = freier_name(quelle["pfad"], KORB, posixpath.basename(pfad.rstrip("/")) or "unbenannt")
            status, geklappt = self._move(source, pfad, f"{KORB}/{name}")
            if not geklappt:
                ergebnis = self._gast_verschieben(source, pfad, f"{KORB}/{name}")
                status, geklappt = ergebnis[0], ergebnis[1]
                if geklappt:
                    pfad_merken = ergebnis[2]
                    ok.append({"source": source, "path": pfad, "message": "in den Papierkorb verschoben"})
                    try:
                        herkunft_aendern(quelle, name, pfad_merken)
                    except OSError:
                        pass
                    continue
            if geklappt:
                ok.append({"source": source, "path": pfad, "message": "in den Papierkorb verschoben"})
                try:
                    herkunft_aendern(quelle, name, pfad)
                except OSError:
                    pass
            else:
                fehler.append({"source": source, "path": pfad, "message": f"Verschieben in den Papierkorb nicht möglich ({status})"})
        return ok, fehler

    def do_POST(self):
        """Wiederherstellen aus dem Papierkorb (Menüpunkt im Datei-Manager), mit den Rechten des Benutzers."""
        if urlsplit(self.path).path != "/dateien-api/wiederherstellen":
            return self._senden(404, {"status": 404, "message": "nicht gefunden"})
        laenge = int(self.headers.get("Content-Length") or 0)
        try:
            daten = json.loads(self.rfile.read(laenge) if laenge else b"{}")
            namen = daten.get("namen") or []
            source = daten.get("quelle") or "Stick"
            assert isinstance(namen, list) and len(namen) <= 200 and isinstance(source, str)
        except (ValueError, AssertionError, AttributeError):
            return self._senden(400, {"status": 400, "message": "ungültige Anfrage"})
        quelle = QUELLEN.get(source)
        if not quelle:
            return self._senden(400, {"status": 400, "message": "unbekannter Speicher"})
        # Angemeldet? (Quantum prüft das Token/Cookie)
        status, _, _ = self._quantum("GET", "/api/users?username=self")
        if status != 200:
            return self._senden(401, {"status": 401, "message": "nicht angemeldet"})
        herkunft = herkunft_lesen(quelle)
        ok, fehler = [], []
        for name in namen:
            if not isinstance(name, str) or not name or "/" in name or name in (".", ".."):
                fehler.append({"name": str(name), "grund": "ungültiger Name"})
                continue
            if not os.path.lexists(os.path.join(quelle["pfad"], KORB.strip("/"), name)):
                fehler.append({"name": name, "grund": "liegt nicht im Papierkorb"})
                continue
            alt = (herkunft.get(name) or {}).get("pfad") or "/" + name
            ordner = posixpath.dirname("/" + alt.strip("/")) or "/"
            if ".." in ordner.split("/") or im_korb(ordner):
                ordner = "/"
            os.makedirs(os.path.join(quelle["pfad"], ordner.strip("/")), exist_ok=True)
            ziel = posixpath.join(ordner, freier_name(quelle["pfad"], ordner, posixpath.basename(alt.rstrip("/")) or name))
            st, geklappt = self._move(source, f"{KORB}/{name}", ziel)
            if geklappt:
                ok.append({"name": name, "ziel": ziel})
                try:
                    herkunft_aendern(quelle, name)
                except OSError:
                    pass
            else:
                fehler.append({"name": name, "grund": f"nicht erlaubt ({st})"})
        return self._senden(200 if not fehler else 207, {"wiederhergestellt": ok, "fehler": fehler})

    def do_DELETE(self):
        url = urlsplit(self.path)
        laenge = int(self.headers.get("Content-Length") or 0)
        roh = self.rfile.read(laenge) if laenge else b""

        if url.path == "/api/resources/bulk":
            try:
                items = json.loads(roh or b"[]")
                assert isinstance(items, list)
            except (ValueError, AssertionError):
                return self._senden(400, {"status": 400, "message": "ungültige Anfrage"})
            korb = [i for i in items if im_korb(i.get("path", ""))]
            rest = [(i.get("source", ""), i.get("path", "")) for i in items if not im_korb(i.get("path", ""))]
            ok, fehler = self._verschieben(rest)
            if korb:
                status, antwort, _ = self._quantum("DELETE", "/api/resources/bulk", json.dumps(korb).encode())
                try:
                    ergebnis = json.loads(antwort or b"{}")
                    ok += ergebnis.get("succeeded") or []
                    fehler += ergebnis.get("failed") or []
                except ValueError:
                    fehler += [dict(i, message=f"Löschen fehlgeschlagen ({status})") for i in korb]
            status = 200 if not fehler else (207 if ok else 403)
            return self._senden(status, {"succeeded": ok, "failed": fehler})

        if url.path == "/api/resources":
            q = parse_qs(url.query)
            pfad = (q.get("path") or [""])[0]
            source = (q.get("source") or [""])[0]
            if im_korb(pfad):
                status, antwort, typ = self._quantum("DELETE", self.path)
                return self._senden(status, antwort, typ)
            ok, fehler = self._verschieben([(source, pfad)])
            if ok:
                return self._senden(200, b"", "text/plain")
            return self._senden(403, {"status": 403, "message": fehler[0]["message"]})

        return self._senden(404, {"status": 404, "message": "nicht gefunden"})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), Weiche).serve_forever()

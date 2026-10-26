#!/usr/bin/env python3
"""Papierkorb-Weiche: nginx schickt nur die Lösch-Anfragen des Datei-Managers hierher.

Statt endgültig zu löschen, wird mit den Rechten des angemeldeten Benutzers nach /Papierkorb
verschoben (Quantum: PATCH /api/resources, action "move", rename bei Namensgleichheit).
Was schon im Papierkorb liegt, wird wirklich gelöscht (Anfrage geht unverändert an Quantum).
Schlägt das Verschieben fehl, wird NICHT gelöscht, der Eintrag kommt als "failed" zurück.
"""
import http.client
import json
import os
import time

try:
    import fcntl
except ImportError:  # nur zum Testen unter Windows
    fcntl = None
import posixpath
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

QUANTUM_HOST = "127.0.0.1"
QUANTUM_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8081
LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8082
KORB = "/Papierkorb"
STICK = os.environ.get("DATEIEN_STICK", "/mnt/stick")
HERKUNFT = os.environ.get("DATEIEN_HERKUNFT", "/data/papierkorb_herkunft.json")
SPERRE = os.environ.get("DATEIEN_SPERRE", "/tmp/gaeste.lock")
WEITERGEBEN = ("Authorization", "Cookie", "X-Forwarded-For", "X-Real-IP", "X-Forwarded-Proto", "X-Forwarded-Host", "User-Agent")


def freier_name(name):
    """Name im Papierkorb, der noch nicht vergeben ist: „bild.jpg“, „bild (1).jpg“, …"""
    stamm, endung = os.path.splitext(name) if not name.startswith(".") else (name, "")
    kandidat, n = name, 0
    while os.path.lexists(os.path.join(STICK, KORB.strip("/"), kandidat)):
        n += 1
        kandidat = f"{stamm} ({n}){endung}"
    return kandidat


def herkunft_merken(name_im_korb, pfad):
    with open(SPERRE, "a") as sperre:
        if fcntl:
            fcntl.flock(sperre, fcntl.LOCK_EX)
        try:
            with open(HERKUNFT, encoding="utf-8") as f:
                daten = json.load(f)
        except (OSError, ValueError):
            daten = {}
        daten[name_im_korb] = {"pfad": "/" + pfad.strip("/"), "zeit": int(time.time())}
        with open(HERKUNFT + ".neu", "w", encoding="utf-8") as f:
            json.dump(daten, f, ensure_ascii=False)
        os.replace(HERKUNFT + ".neu", HERKUNFT)


def herkunft_lesen():
    try:
        with open(HERKUNFT, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def herkunft_vergessen(name_im_korb):
    with open(SPERRE, "a") as sperre:
        if fcntl:
            fcntl.flock(sperre, fcntl.LOCK_EX)
        daten = herkunft_lesen()
        daten.pop(name_im_korb, None)
        with open(HERKUNFT + ".neu", "w", encoding="utf-8") as f:
            json.dump(daten, f, ensure_ascii=False)
        os.replace(HERKUNFT + ".neu", HERKUNFT)


def freies_ziel(ordner, name):
    """Freier Name im Zielordner (Stick-Pfad), bei Gleichstand „name (1).ext“."""
    stamm, endung = os.path.splitext(name) if not name.startswith(".") else (name, "")
    kandidat, n = name, 0
    while os.path.lexists(os.path.join(STICK, ordner.strip("/"), kandidat)):
        n += 1
        kandidat = f"{stamm} ({n}){endung}"
    return kandidat


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

    def _verschieben(self, eintraege):
        """eintraege: [(source, path)] -> (succeeded, failed) im Format von BulkDeleteResponse"""
        ok, fehler = [], []
        for source, pfad in eintraege:
            name = freier_name(posixpath.basename(pfad.rstrip("/")) or "unbenannt")
            anfrage = {"action": "move", "rename": False, "overwrite": False, "items": [
                {"fromSource": source, "fromPath": pfad, "toSource": source, "toPath": f"{KORB}/{name}"}]}
            status, antwort, _ = self._quantum("PATCH", "/api/resources", json.dumps(anfrage).encode())
            if status in (200, 204):
                try:
                    ergebnis = json.loads(antwort or b"{}")
                except ValueError:
                    ergebnis = {}
                if ergebnis.get("failed"):
                    fehler.append({"source": source, "path": pfad, "message": "Verschieben in den Papierkorb fehlgeschlagen"})
                else:
                    ok.append({"source": source, "path": pfad, "message": "in den Papierkorb verschoben"})
                    try:
                        herkunft_merken(name, pfad)
                    except OSError:
                        pass
            else:
                fehler.append({"source": source, "path": pfad, "message": f"Verschieben in den Papierkorb nicht erlaubt ({status})"})
        return ok, fehler

    def do_POST(self):
        """Wiederherstellen aus dem Papierkorb (Menüpunkt im Datei-Manager), mit den Rechten des Benutzers."""
        if urlsplit(self.path).path != "/dateien-api/wiederherstellen":
            return self._senden(404, {"status": 404, "message": "nicht gefunden"})
        laenge = int(self.headers.get("Content-Length") or 0)
        try:
            namen = json.loads(self.rfile.read(laenge) if laenge else b"{}").get("namen") or []
            assert isinstance(namen, list) and len(namen) <= 200
        except (ValueError, AssertionError, AttributeError):
            return self._senden(400, {"status": 400, "message": "ungültige Anfrage"})
        # Angemeldet? (Quantum prüft das Token/Cookie)
        status, _, _ = self._quantum("GET", "/api/users?username=self")
        if status != 200:
            return self._senden(401, {"status": 401, "message": "nicht angemeldet"})
        herkunft = herkunft_lesen()
        ok, fehler = [], []
        for name in namen:
            if not isinstance(name, str) or not name or "/" in name or name in (".", ".."):
                fehler.append({"name": str(name), "grund": "ungültiger Name"})
                continue
            if not os.path.lexists(os.path.join(STICK, KORB.strip("/"), name)):
                fehler.append({"name": name, "grund": "liegt nicht im Papierkorb"})
                continue
            alt = (herkunft.get(name) or {}).get("pfad") or "/" + name
            ordner = posixpath.dirname("/" + alt.strip("/")) or "/"
            if ".." in ordner.split("/") or im_korb(ordner):
                ordner = "/"
            os.makedirs(os.path.join(STICK, ordner.strip("/")), exist_ok=True)
            ziel = posixpath.join(ordner, freies_ziel(ordner, posixpath.basename(alt.rstrip("/")) or name))
            anfrage = {"action": "move", "rename": False, "overwrite": False, "items": [
                {"fromSource": "Stick", "fromPath": f"{KORB}/{name}", "toSource": "Stick", "toPath": ziel}]}
            st, antwort, _ = self._quantum("PATCH", "/api/resources", json.dumps(anfrage).encode())
            try:
                misslungen = bool(json.loads(antwort or b"{}").get("failed"))
            except ValueError:
                misslungen = False
            if st in (200, 204) and not misslungen:
                ok.append({"name": name, "ziel": ziel})
                try:
                    herkunft_vergessen(name)
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

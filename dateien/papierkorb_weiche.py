#!/usr/bin/env python3
"""Papierkorb-Weiche: nginx schickt nur die Lösch-Anfragen des Datei-Managers hierher.

Statt endgültig zu löschen, wird mit den Rechten des angemeldeten Benutzers nach /Papierkorb
verschoben (Quantum: PATCH /api/resources, action "move", rename bei Namensgleichheit).
Was schon im Papierkorb liegt, wird wirklich gelöscht (Anfrage geht unverändert an Quantum).
Schlägt das Verschieben fehl, wird NICHT gelöscht, der Eintrag kommt als "failed" zurück.
"""
import http.client
import json
import posixpath
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

QUANTUM_HOST = "127.0.0.1"
QUANTUM_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8081
LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8082
KORB = "/Papierkorb"
WEITERGEBEN = ("Authorization", "Cookie", "X-Forwarded-For", "X-Real-IP", "X-Forwarded-Proto", "X-Forwarded-Host", "User-Agent")


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
            name = posixpath.basename(pfad.rstrip("/")) or "unbenannt"
            anfrage = {"action": "move", "rename": True, "overwrite": False, "items": [
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
            else:
                fehler.append({"source": source, "path": pfad, "message": f"Verschieben in den Papierkorb nicht erlaubt ({status})"})
        return ok, fehler

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

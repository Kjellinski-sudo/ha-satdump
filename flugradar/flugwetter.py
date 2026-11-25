#!/usr/bin/env python3
"""Flugwetter: sammelt Wind und Aussentemperatur, die Flugzeuge per Mode-S (Comm-B)
melden, und schreibt daraus Hoehenprofil, Frostgrenze und Jetstream nach Home Assistant.
Laeuft als Schleife (alle 30 s), haelt die Messungen der letzten 60 Minuten im Speicher."""
import json, math, os, time, urllib.request

AIRCRAFT = "/run/readsb/aircraft.json"
TOKEN = os.environ.get("SUPERVISOR_TOKEN", "")
FENSTER = 3600          # Sekunden, die Messungen gueltig bleiben
BAENDER = [(0, 1500), (1500, 3000), (3000, 6000), (6000, 9000), (9000, 13000)]
proben = []             # (zeit, hex, hoehe_m, wd, ws_kmh, oat)
zuletzt = {}            # hex -> zeit der letzten Uebernahme (max. 1 Probe/Min. je Flieger)


def post(pfad, daten):
    if not TOKEN:
        return
    req = urllib.request.Request(
        "http://supervisor/core/api/" + pfad, data=json.dumps(daten).encode(), method="POST",
        headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=8).read()
    except Exception as e:  # HA kurz nicht erreichbar: naechste Runde
        print("Flugwetter: HA nicht erreichbar:", e, flush=True)


def einlesen():
    try:
        with open(AIRCRAFT) as f:
            daten = json.load(f)
    except Exception:
        return
    jetzt = time.time()
    for a in daten.get("aircraft", []):
        alt = a.get("alt_baro")
        if not isinstance(alt, (int, float)) or alt < 0:
            continue
        ws, wd, oat = a.get("ws"), a.get("wd"), a.get("oat")
        if ws is None and oat is None:
            continue
        hx = a.get("hex", "")
        if jetzt - zuletzt.get(hx, 0) < 60:
            continue
        zuletzt[hx] = jetzt
        proben.append((jetzt, hx, alt * 0.3048,
                       wd if isinstance(wd, (int, float)) else None,
                       ws * 1.852 if isinstance(ws, (int, float)) else None,
                       oat if isinstance(oat, (int, float)) else None))
    grenze = jetzt - FENSTER
    proben[:] = [p for p in proben if p[0] >= grenze]
    for k in [k for k, t in zuletzt.items() if t < grenze]:
        del zuletzt[k]


def wind_mittel(liste):
    """Vektor-Mittel von (richtung, kmh) -> (richtung, kmh)."""
    if not liste:
        return None, None
    u = sum(-s * math.sin(math.radians(d)) for d, s in liste) / len(liste)
    v = sum(-s * math.cos(math.radians(d)) for d, s in liste) / len(liste)
    kmh = math.hypot(u, v)
    richtung = (math.degrees(math.atan2(-u, -v)) + 360) % 360
    return round(richtung), round(kmh)


def auswerten():
    jetzt = time.time()
    baender = []
    for lo, hi in BAENDER:
        b = [p for p in proben if lo <= p[2] < hi]
        wind = [(p[3], p[4]) for p in b if p[3] is not None and p[4] is not None]
        temp = [p[5] for p in b if p[5] is not None]
        richtung, kmh = wind_mittel(wind)
        baender.append({"von_m": lo, "bis_m": hi, "richtung": richtung, "kmh": kmh,
                        "temp": round(sum(temp) / len(temp), 1) if temp else None,
                        "n": len(b)})
    # Frostgrenze: lineare Regression Temperatur ueber Hoehe (nur bis 7 km)
    t = [(p[2], p[5]) for p in proben if p[5] is not None and p[2] < 7000]
    frost = None
    if len(t) >= 3 and max(h for h, _ in t) - min(h for h, _ in t) > 1000:
        n = len(t)
        mh = sum(h for h, _ in t) / n
        mt = sum(x for _, x in t) / n
        sxx = sum((h - mh) ** 2 for h, _ in t)
        sxy = sum((h - mh) * (x - mt) for h, x in t)
        if sxx > 0 and sxy < 0:
            b = sxy / sxx
            frost = max(0, round((0 - (mt - b * mh)) / b / 50) * 50)
    # Jetstream: staerkster Wind oberhalb 6 km
    oben = [p for p in proben if p[2] >= 6000 and p[4] is not None and p[3] is not None]
    jet = max(oben, key=lambda p: p[4]) if oben else None
    reise = [p[5] for p in proben if p[2] >= 9000 and p[5] is not None]
    alter = round((jetzt - max(p[0] for p in proben)) / 60) if proben else None

    post("states/sensor.flugwetter_frostgrenze", {
        "state": frost if frost is not None else "unknown",
        "attributes": {"friendly_name": "Flugwetter Frostgrenze", "unit_of_measurement": "m",
                       "icon": "mdi:snowflake-thermometer", "messungen": len(t)}})
    post("states/sensor.flugwetter_jetstream", {
        "state": round(jet[4]) if jet else "unknown",
        "attributes": {"friendly_name": "Flugwetter Jetstream", "unit_of_measurement": "km/h",
                       "icon": "mdi:weather-windy", "richtung": round(jet[3]) if jet else None,
                       "hoehe_m": round(jet[2] / 100) * 100 if jet else None}})
    post("states/sensor.flugwetter_temperatur_reiseflug", {
        "state": round(sum(reise) / len(reise), 1) if reise else "unknown",
        "attributes": {"friendly_name": "Flugwetter Temperatur Reiseflughöhe",
                       "unit_of_measurement": "°C", "icon": "mdi:thermometer-chevron-up",
                       "messungen": len(reise)}})
    post("states/sensor.flugwetter_profil", {
        "state": len(proben),
        "attributes": {"friendly_name": "Flugwetter Höhenprofil", "unit_of_measurement": "Messungen",
                       "icon": "mdi:weather-cloudy-arrow-right", "baender": baender,
                       "alter_min": alter, "fenster_min": FENSTER // 60}})


def main():
    time.sleep(60)
    runde = 0
    while True:
        einlesen()
        runde += 1
        if runde % 3 == 0:      # alle 30 s auswerten
            auswerten()
        time.sleep(10)


if __name__ == "__main__":
    main()

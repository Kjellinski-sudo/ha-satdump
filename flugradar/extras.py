#!/usr/bin/env python3
"""Flugradar-Extras (ab v0.3.0):
- Details zum naechsten Flieger (Airline, Route, Foto) ueber adsbdb.com
- Statistik/Sammelalbum (Flieger pro Tag, Top-Airlines, Typen, Rekorde), Ereignis "flugradar_fang"
- Kondensstreifen-Einschaetzung aus Temperatur/Feuchte in Reiseflughoehe (Open-Meteo)
- ISS-Ueberfluege (TLE von Celestrak, Berechnung mit skyfield)
- Pollen und UV (Open-Meteo / Copernicus CAMS)
Alles schreibt Sensoren nach Home Assistant. Standort kommt aus HA (fuer externe Abfragen gerundet)."""
import json, math, os, time, urllib.request, urllib.parse, datetime

AIRCRAFT = "/run/readsb/aircraft.json"
TOKEN = os.environ.get("SUPERVISOR_TOKEN", "")
DATEN = "/data/flugstats.json"
UA = {"User-Agent": "ha-flugradar/0.3"}
LAT = LON = None


def http_json(url, headers=None, data=None, method="GET", timeout=12):
    req = urllib.request.Request(url, data=data, method=method, headers=headers or UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode() or "null")


def ha(pfad, daten=None):
    if not TOKEN:
        return None
    h = {"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"}
    try:
        if daten is None:
            return http_json("http://supervisor/core/api/" + pfad, h)
        return http_json("http://supervisor/core/api/" + pfad, h, json.dumps(daten).encode(), "POST")
    except Exception as e:
        print("Extras: HA-Fehler", pfad, e, flush=True)
        return None


def sensor(eid, state, attrs):
    ha("states/" + eid, {"state": state, "attributes": attrs})


# ------------------------------------------------------------------ Statistik
def stats_laden():
    try:
        with open(DATEN) as f:
            return json.load(f)
    except Exception:
        return {"start": time.time(), "tage": {}, "typen": {}, "rekord": {}}


def stats_speichern(s):
    tmp = DATEN + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f)
    os.replace(tmp, DATEN)


def statistik(stats, flieger):
    heute = datetime.date.today().isoformat()
    tag = stats["tage"].setdefault(heute, {"hex": [], "airlines": {}})
    hexe = set(tag["hex"])
    rek = stats["rekord"]
    neu_typ = []
    for a in flieger:
        hx = a.get("hex")
        if not hx:
            continue
        cs = (a.get("flight") or "").strip()
        typ = a.get("t") or ""
        if hx not in hexe:
            hexe.add(hx)
            if len(cs) >= 4 and cs[:3].isalpha():
                tag["airlines"][cs[:3]] = tag["airlines"].get(cs[:3], 0) + 1
            if typ:
                t = stats["typen"].setdefault(typ, {"erst": heute, "anzahl": 0, "desc": a.get("desc", "")})
                t["anzahl"] += 1
                if t["anzahl"] == 1:
                    neu_typ.append(a)
        dist = a.get("r_dst")
        if isinstance(dist, (int, float)) and dist * 1.852 > rek.get("km", 0):
            rek.update(km=round(dist * 1.852, 1), km_cs=cs or hx, km_datum=heute)
        alt = a.get("alt_baro")
        if isinstance(alt, (int, float)) and alt * 0.3048 > rek.get("hoehe_m", 0):
            rek.update(hoehe_m=round(alt * 0.3048), hoehe_cs=cs or hx, hoehe_datum=heute)
        gs = a.get("gs")
        if isinstance(gs, (int, float)) and gs * 1.852 > rek.get("kmh", 0) and gs < 800:
            rek.update(kmh=round(gs * 1.852), kmh_cs=cs or hx, kmh_datum=heute)
    tag["hex"] = list(hexe)
    for d in sorted(stats["tage"])[:-30]:      # nur 30 Tage aufheben
        del stats["tage"][d]
    # "Fang des Tages": neuer Typ, aber erst nach 3 Tagen Eingewoehnung (sonst ist alles neu)
    if time.time() - stats["start"] > 3 * 86400:
        for a in neu_typ:
            ha("events/flugradar_fang", {"hex": a.get("hex"), "cs": (a.get("flight") or "").strip(),
                                          "typ": a.get("t"), "desc": a.get("desc", ""), "reg": a.get("r", ""),
                                          "km": round((a.get("r_dst") or 0) * 1.852, 1)})
    top = sorted(tag["airlines"].items(), key=lambda x: -x[1])[:5]
    woche = [{"tag": d, "anzahl": len(v["hex"])} for d, v in sorted(stats["tage"].items())[-7:]]
    sensor("sensor.flugradar_heute", len(hexe), {
        "friendly_name": "Flugradar Flieger heute", "unit_of_measurement": "Flieger", "icon": "mdi:airplane-takeoff",
        "top_airlines": [{"code": c, "anzahl": n} for c, n in top], "woche": woche,
        "album_typen": len(stats["typen"]),
        "album_neu": sorted(([k, v["erst"], v.get("desc", "")] for k, v in stats["typen"].items()),
                            key=lambda x: x[1], reverse=True)[:8],
        "rekord": rek, "seit": datetime.date.fromtimestamp(stats["start"]).isoformat()})


# ------------------------------------------------------------- Flieger-Details
cache = {}


def details(flieger):
    pos = [a for a in flieger if a.get("lat") is not None and a.get("r_dst") is not None]
    if not pos:
        sensor("sensor.flugradar_naechster_details", "keiner", {"friendly_name": "Flugradar nächster Flieger Details",
                                                                 "icon": "mdi:airplane-search"})
        return
    a = min(pos, key=lambda x: x["r_dst"])
    hx = a.get("hex")
    cs = (a.get("flight") or "").strip()
    key = hx + "|" + cs
    if key not in cache:
        info = {"airline": "", "von": "", "nach": "", "von_iata": "", "nach_iata": "", "foto": "",
                "hersteller": "", "modell": "", "betreiber": ""}
        try:
            if cs:
                r = http_json("https://api.adsbdb.com/v0/callsign/" + urllib.parse.quote(cs), UA).get("response", {})
                fr = r.get("flightroute") if isinstance(r, dict) else None
                if fr:
                    info["airline"] = (fr.get("airline") or {}).get("name", "")
                    o, d = fr.get("origin") or {}, fr.get("destination") or {}
                    info.update(von=o.get("municipality") or o.get("name", ""), nach=d.get("municipality") or d.get("name", ""),
                                von_iata=o.get("iata_code", ""), nach_iata=d.get("iata_code", ""))
        except Exception:
            pass
        try:
            r = http_json("https://api.adsbdb.com/v0/aircraft/" + hx, UA).get("response", {})
            ac = r.get("aircraft") if isinstance(r, dict) else None
            if ac:
                info.update(foto=ac.get("url_photo_thumbnail") or ac.get("url_photo") or "",
                            hersteller=ac.get("manufacturer", ""), modell=ac.get("type", ""),
                            betreiber=ac.get("registered_owner", ""))
        except Exception:
            pass
        cache[key] = info
        if len(cache) > 300:
            cache.pop(next(iter(cache)))
    i = cache[key]
    sensor("sensor.flugradar_naechster_details", cs or a.get("r") or hx.upper(), {
        "friendly_name": "Flugradar nächster Flieger Details", "icon": "mdi:airplane-search",
        "hex": hx, "rufzeichen": cs, "kennzeichen": a.get("r", ""), "typ": a.get("t", ""),
        "typ_name": a.get("desc", "") or (i["hersteller"] + " " + i["modell"]).strip(),
        "hoehe_m": round(a["alt_baro"] * 0.3048) if isinstance(a.get("alt_baro"), (int, float)) else 0,
        "km": round(a["r_dst"] * 1.852, 1), "richtung": round(a.get("r_dir") or 0),
        "kmh": round((a.get("gs") or 0) * 1.852), **i})


# --------------------------------------------------------------- Open-Meteo
def kondensstreifen():
    url = ("https://api.open-meteo.com/v1/forecast?latitude=%.2f&longitude=%.2f&timezone=Europe%%2FBerlin"
           "&forecast_days=1&hourly=temperature_250hPa,relative_humidity_250hPa,temperature_300hPa,"
           "relative_humidity_300hPa" % (LAT, LON))
    d = http_json(url, UA)["hourly"]
    i = min(range(len(d["time"])), key=lambda k: abs(datetime.datetime.fromisoformat(d["time"][k]) - datetime.datetime.now()))

    def eis(t, rh):  # relative Feuchte ueber Eis aus RH ueber Wasser
        ew = 6.112 * math.exp(17.62 * t / (243.12 + t))
        ei = 6.112 * math.exp(22.46 * t / (272.62 + t))
        return rh * ew / ei

    stufen = []
    for p, hoehe in (("250hPa", 10400), ("300hPa", 9200)):
        t, rh = d["temperature_" + p][i], d["relative_humidity_" + p][i]
        if t is None or rh is None:
            continue
        rhi = eis(t, rh)
        # vereinfachtes Schmidt-Appleman: bei < -40 °C bilden sich Streifen, ueber Eis-Uebersaettigung bleiben sie
        if t > -38:
            s = "keine"
        elif rhi >= 100:
            s = "langlebig"
        else:
            s = "kurzlebig"
        stufen.append({"hoehe_m": hoehe, "temp": round(t, 1), "rh": round(rh), "rh_eis": round(rhi), "stufe": s})
    rang = {"keine": 0, "kurzlebig": 1, "langlebig": 2}
    best = max(stufen, key=lambda x: rang[x["stufe"]])["stufe"] if stufen else "unbekannt"
    sensor("sensor.flugwetter_kondensstreifen", best, {
        "friendly_name": "Flugwetter Kondensstreifen", "icon": "mdi:weather-cloudy-arrow-right", "hoehen": stufen,
        "quelle": "Open-Meteo (Modell), vereinfachtes Schmidt-Appleman-Kriterium"})


def pollen_uv():
    url = ("https://air-quality-api.open-meteo.com/v1/air-quality?latitude=%.2f&longitude=%.2f"
           "&timezone=Europe%%2FBerlin&forecast_days=1&hourly=alder_pollen,birch_pollen,grass_pollen,"
           "mugwort_pollen,ragweed_pollen,uv_index" % (LAT, LON))
    d = http_json(url, UA)["hourly"]
    namen = {"alder_pollen": "Erle", "birch_pollen": "Birke", "grass_pollen": "Gräser",
             "mugwort_pollen": "Beifuß", "ragweed_pollen": "Ambrosia"}
    grenzen = {"alder_pollen": (10, 50), "birch_pollen": (10, 100), "grass_pollen": (5, 50),
               "mugwort_pollen": (5, 50), "ragweed_pollen": (5, 30)}
    pol = []
    stufe_max = 0
    for k, n in namen.items():
        v = max([x for x in d.get(k, []) if x is not None] or [0])
        lo, hi = grenzen[k]
        st = 0 if v < 1 else (1 if v < lo else (2 if v < hi else 3))
        stufe_max = max(stufe_max, st)
        if st:
            pol.append({"art": n, "wert": round(v), "stufe": ["keine", "gering", "mittel", "hoch"][st]})
    uv = max([x for x in d.get("uv_index", []) if x is not None] or [0])
    sensor("sensor.pollen_heute", ["keine", "gering", "mittel", "hoch"][stufe_max], {
        "friendly_name": "Pollenflug heute", "icon": "mdi:flower-pollen", "arten": pol,
        "quelle": "Open-Meteo / Copernicus CAMS"})
    sensor("sensor.uv_index_heute", round(uv, 1), {
        "friendly_name": "UV-Index heute (max.)", "icon": "mdi:weather-sunny-alert", "unit_of_measurement": "UV",
        "quelle": "Open-Meteo / Copernicus CAMS"})


# ---------------------------------------------------------------------- ISS
def iss():
    from skyfield.api import load, wgs84, EarthSatellite
    tle = None
    try:
        tle = urllib.request.urlopen(urllib.request.Request(
            "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=tle", headers=UA), timeout=15).read().decode().splitlines()
    except Exception:
        try:
            j = http_json("https://tle.ivanstanojevic.me/api/tle/25544", UA)
            tle = [j["name"], j["line1"], j["line2"]]
        except Exception:
            tle = None
    if tle and len(tle) >= 3:
        with open("/data/iss.tle", "w") as f:
            f.write(chr(10).join(tle[:3]))
    elif os.path.exists("/data/iss.tle"):
        tle = open("/data/iss.tle").read().splitlines()
    else:
        raise RuntimeError("keine ISS-Bahndaten")
    ts = load.timescale(builtin=True)
    sat = EarthSatellite(tle[1], tle[2], tle[0].strip(), ts)
    eph = load("/data/de421.bsp") if os.path.exists("/data/de421.bsp") else None
    if eph is None:
        os.makedirs("/data", exist_ok=True)
        urllib.request.urlretrieve("https://ssd.jpl.nasa.gov/ftp/eph/planets/bsp/de421.bsp", "/data/de421.bsp")
        eph = load("/data/de421.bsp")
    ort = wgs84.latlon(LAT, LON)
    t0 = ts.now()
    t1 = ts.tt_jd(t0.tt + 2)
    zeiten, ereignisse = sat.find_events(ort, t0, t1, altitude_degrees=10.0)
    ueber = []
    cur = {}
    for t, e in zip(zeiten, ereignisse):
        if e == 0:
            cur = {"start": t}
        elif e == 1 and cur:
            alt, az, _ = (sat - ort).at(t).altaz()
            cur.update(hoch=t, max_grad=round(alt.degrees))
        elif e == 2 and cur.get("hoch") is not None:
            cur["ende"] = t
            tm = cur["hoch"]
            sonne = (eph["earth"] + ort).at(tm).observe(eph["sun"]).apparent().altaz()[0].degrees
            beleuchtet = sat.at(tm).is_sunlit(eph)
            az0 = (sat - ort).at(cur["start"]).altaz()[1].degrees
            az1 = (sat - ort).at(cur["ende"]).altaz()[1].degrees
            R = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
            ueber.append({"start": cur["start"].utc_datetime().isoformat(), "ende": cur["ende"].utc_datetime().isoformat(),
                          "max_grad": cur["max_grad"], "sichtbar": bool(beleuchtet and sonne < -6),
                          "von": R[round(az0 / 45) % 8], "nach": R[round(az1 / 45) % 8],
                          "dauer_min": round((cur["ende"].tt - cur["start"].tt) * 1440)})
            cur = {}
    sicht = [u for u in ueber if u["sichtbar"]]
    n = sicht[0] if sicht else None
    sensor("sensor.iss_naechster_sichtbarer_ueberflug", n["start"] if n else "unknown", {
        "friendly_name": "ISS nächster sichtbarer Überflug", "icon": "mdi:space-station", "device_class": "timestamp",
        **({k: v for k, v in n.items() if k != "start"} if n else {}),
        "alle": ueber[:8]})


def main():
    global LAT, LON
    time.sleep(90)
    cfg = ha("config") or {}
    LAT, LON = cfg.get("latitude"), cfg.get("longitude")
    stats = stats_laden()
    letzte = {"wetter": 0, "pollen": 0, "iss": 0, "speichern": 0}
    while True:
        jetzt = time.time()
        try:
            with open(AIRCRAFT) as f:
                flieger = json.load(f).get("aircraft", [])
            statistik(stats, flieger)
            details(flieger)
        except Exception as e:
            print("Extras: Flieger", e, flush=True)
        if LAT is not None:
            for name, abstand, fn in (("wetter", 1800, kondensstreifen), ("pollen", 3600, pollen_uv), ("iss", 6 * 3600, iss)):
                if jetzt - letzte[name] > abstand:
                    try:
                        fn()
                        letzte[name] = jetzt
                    except Exception as e:
                        print("Extras:", name, e, flush=True)
                        letzte[name] = jetzt - abstand + 600   # in 10 min erneut
        if jetzt - letzte["speichern"] > 300:
            stats_speichern(stats)
            letzte["speichern"] = jetzt
        time.sleep(30)


if __name__ == "__main__":
    main()

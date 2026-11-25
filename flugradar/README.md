# Flugradar (ADS-B)

Empfängt mit einem RTL-SDR-Stick die ADS-B-Signale der Flugzeuge (1090 MHz) mit
[readsb](https://github.com/wiedehopf/readsb) und zeigt sie auf der tar1090-Karte
(Image: sdr-enthusiasts/docker-adsb-ultrafeeder). Der Standort kommt aus der
Home-Assistant-Konfiguration und wird nicht gespeichert.

Sensoren: `sensor.flugradar_flugzeuge`, `sensor.flugradar_ueber_mir`, `sensor.flugradar_naechster`.
Ereignis `flugradar_besonders` (grund: rettung | militaer | tief), je Flieger max. stündlich.

Der Stick wird exklusiv belegt: nicht gleichzeitig mit der SatDump-App betreiben.

## Flugwetter (ab 0.2.0)
Aus den Mode-S-Meldungen (Wind, Aussentemperatur) der letzten 60 Minuten: `sensor.flugwetter_frostgrenze`, `sensor.flugwetter_jetstream`, `sensor.flugwetter_temperatur_reiseflug`, `sensor.flugwetter_profil` (Hoehenbaender als Attribut). Ist-Zustand, keine Vorhersage.

## Extras (ab 0.3.0)
Notfall-Squawk 7500/7600/7700 (Ereignis grund=notfall), `sensor.flugradar_naechster_details` (Airline/Route/Foto via adsbdb.com), `sensor.flugradar_heute` (Statistik, Sammelalbum, Rekorde; Ereignis `flugradar_fang`), `sensor.flugwetter_kondensstreifen`, `sensor.iss_naechster_sichtbarer_ueberflug` (skyfield), `sensor.pollen_heute`, `sensor.uv_index_heute` (Open-Meteo/CAMS).

# Flugradar (ADS-B)

Empfängt mit einem RTL-SDR-Stick die ADS-B-Signale der Flugzeuge (1090 MHz) mit
[readsb](https://github.com/wiedehopf/readsb) und zeigt sie auf der tar1090-Karte
(Image: sdr-enthusiasts/docker-adsb-ultrafeeder). Der Standort kommt aus der
Home-Assistant-Konfiguration und wird nicht gespeichert.

Sensoren: `sensor.flugradar_flugzeuge`, `sensor.flugradar_ueber_mir`, `sensor.flugradar_naechster`.
Ereignis `flugradar_besonders` (grund: rettung | militaer | tief), je Flieger max. stündlich.

Der Stick wird exklusiv belegt: nicht gleichzeitig mit der SatDump-App betreiben.

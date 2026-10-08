# ha-satdump

Home-Assistant-App, die mit einem RTL-SDR-Stick automatisch Wetterbilder der
Meteor-M2-3/M2-4-Satelliten (LRPT, 137,9 MHz) empfängt. Grundlage ist
[SatDump](https://www.satdump.org/) aus dem Debian-Paket.

## Installation

1. Home Assistant → Einstellungen → Apps → App-Store → ⋮ → Repositories →
   `https://github.com/Kjellinski-sudo/ha-satdump` hinzufügen.
2. App „SatDump Wettersatelliten“ installieren.
3. In der Konfiguration `latitude`, `longitude` und `altitude` des Standorts eintragen.
4. Starten. Die Bilder landen unter `/media/satdump/`, das jeweils neueste als
   `latest.png` (sichtbar) und `latest_ir.png` (Infrarot).

Antenne: V-Dipol, 2 × ca. 53 cm, 120°, waagerecht, Nord-Süd, mit freier Sicht zum Himmel.

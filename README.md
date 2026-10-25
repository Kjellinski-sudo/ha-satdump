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

## Dateien (FileBrowser Quantum)

Datei-Manager nur für den USB-Stick (Name „ESD-USB“) am Home-Assistant-Pi, im Neon-Design des SecuriPi-Panels.
- [FileBrowser Quantum](https://github.com/gtsteffaniak/filebrowser) v2.0.2-stable (gepflegter Nachfolger des archivierten File Browser), Download per Prüfsumme geprüft. Bis v0.1.1 lief das alte File Browser (Git-Tag `dateien-v0.1.1`).
- Kein offener Port: erreichbar nur über den Cloudflare-Tunnel (intern `http://1791b5d0-dateien:8080`), davor Cloudflare Access.
- Benutzername und Passwort (mind. 12 Zeichen) in der App-Konfiguration eintragen; ohne startet die App nicht.
- Keine Selbstregistrierung, Teilen-Links für neue Benutzer aus. Meldet Stick-Belegung und Anmeldungen (erfolgreich/fehlgeschlagen) an Home Assistant.

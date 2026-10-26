#!/bin/bash
# Datei-Manager (FileBrowser Quantum) nur für die USB-Sticks. Benutzer und Passwort kommen aus der
# App-Konfiguration (setzt Kjell selbst) und werden nie ins Protokoll geschrieben.
set -u

OPT=/data/options.json
MNT=/mnt/stick
CONF=/tmp/fbq-config.yaml

LABEL=$(jq -r '.stick_label' "$OPT")
LABEL2=$(jq -r '.stick2_label // ""' "$OPT")
MNT2=/mnt/stick2
QUELLEN=/tmp/quellen.json
USER_NAME=$(jq -r '.username' "$OPT")
USER_PW=$(jq -r '.password' "$OPT")
PUSH_DIENST=$(jq -r '.push_dienst // "mobile_app_kjells_apfel"' "$OPT")
# Zufallspasswörter per Push erst, wenn HA Dienstaufrufe nicht mehr in der Datenbank speichert
PW_PUSH=$(jq -r '.passwort_per_push // false' "$OPT")

if [ -z "$USER_NAME" ] || [ "${#USER_PW}" -lt 12 ]; then
    echo "[dateien] Bitte zuerst in der App-Konfiguration einen Benutzernamen und ein Passwort (mindestens 12 Zeichen) eintragen."
    exit 1
fi

# Sticks einbinden: vfat/exFAT, ohne Ausführen
einhaengen() {
    local dev=$1 mnt=$2
    [ -b "$dev" ] || return 1
    mkdir -p "$mnt"
    if ! mountpoint -q "$mnt"; then
        mount -o rw,nosuid,nodev,noexec,uid=0,gid=0,umask=0022,iocharset=utf8 "$dev" "$mnt" || return 1
    fi
    echo "[dateien] Stick „$(blkid -s LABEL -o value "$dev" 2>/dev/null)“ eingebunden: $dev -> $mnt"
}

# Erster Stick ist Pflicht: per Name (Label), sonst /dev/sda1 wie bisher
DEV1=$(blkid -L "$LABEL" 2>/dev/null || true)
[ -n "$DEV1" ] || DEV1=/dev/sda1
if ! einhaengen "$DEV1" "$MNT"; then
    echo "[dateien] USB-Stick „$LABEL“ nicht gefunden. Steckt er im Home-Assistant-Pi?"
    exit 1
fi

# Zweiter Stick ist freiwillig: per Name, oder (Name leer) der erste andere USB-Stick mit FAT/exFAT.
# Fehlt er, läuft alles nur mit dem ersten.
STICK2=false
DEV2=""
if [ -n "$LABEL2" ]; then
    DEV2=$(blkid -L "$LABEL2" 2>/dev/null || true)
else
    for d in /dev/sd[a-z]1; do
        [ -b "$d" ] && [ "$d" != "$DEV1" ] || continue
        case "$(blkid -s TYPE -o value "$d" 2>/dev/null)" in vfat|exfat) DEV2=$d; break ;; esac
    done
fi
if [ -n "$DEV2" ] && [ "$DEV2" != "$DEV1" ] && einhaengen "$DEV2" "$MNT2"; then
    STICK2=true
else
    echo "[dateien] Kein zweiter Stick gefunden – läuft nur mit dem ersten."
fi

# Quellen für Weiche, Papierkorb und Belegung
jq -n --arg m1 "$MNT" --arg m2 "$MNT2" --argjson zwei "$STICK2" '[
    {name: "Stick", pfad: $m1, sensor: "sensor.dateien_stick_belegt", titel: "Stick",
     herkunft: "/data/papierkorb_herkunft.json", korbliste: "/data/papierkorb.json", korbsensor: "sensor.dateien_papierkorb"}
  ] + (if $zwei then [
    {name: "Stick 2", pfad: $m2, sensor: "sensor.dateien_stick2_belegt", titel: "Stick 2",
     herkunft: "/data/papierkorb_herkunft_stick2.json", korbliste: "/data/papierkorb_stick2.json", korbsensor: "sensor.dateien_papierkorb_stick2"}
  ] else [] end)' > "$QUELLEN"

cleanup() {
    kill "${BEL_PID:-0}" "${LOG_PID:-0}" 2>/dev/null
    kill "${FB_PID:-0}" "${WEICHE_PID:-0}" 2>/dev/null
    nginx -c /etc/dateien-nginx.conf -s quit 2>/dev/null
    wait "${FB_PID:-0}" 2>/dev/null
    sync
    umount "$MNT" 2>/dev/null
    umount "$MNT2" 2>/dev/null
    exit 0
}
trap cleanup TERM INT

# Konfiguration bei jedem Start neu schreiben (nur im Container, nur für root lesbar).
# Der Admin-Benutzer bekommt bei jedem Start Name und Passwort aus der App-Konfiguration.
# JSON-Zeichenketten sind gültiges YAML, so sind Sonderzeichen im Passwort sicher.
mkdir -p /data/quantum /tmp/fbq-cache
umask 077
cat > "$CONF" <<EOF
server:
  disableUpdateCheck: true
  logging:
    - levels: "info|warning|error"
      apiLevels: "info|warning|error"
      noColors: true
  sources:
    - path: "$MNT"
      name: "Stick"
      config:
        defaultEnabled: true
$(if [ "$STICK2" = true ]; then printf '    - path: "%s"\n      name: "Stick 2"\n      config:\n        defaultEnabled: true\n' "$MNT2"; fi)
  cacheDir: "/tmp/fbq-cache"
  cacheDirCleanup: true
  database:
    path: "/data/quantum/filebrowser.sqlite"
    activity:
      retentionDays: 30
auth:
  tokenExpirationHours: 12
  adminUsername: $(jq -n --arg v "$USER_NAME" '$v')
  adminPassword: $(jq -n --arg v "$USER_PW" '$v')
  methods:
    password:
      enabled: true
      minLength: 12
      signup: false
frontend:
  name: "Dateien"
  description: "Dateien auf den USB-Sticks"
  disableDefaultLinks: true
  externalLinks: []
  loginIcon: "/opt/dateien/logo.svg"
  favicon: "/opt/dateien/logo.svg"
  loginButtonText: "Anmelden"
  styling:
    disableEventThemes: true
    customCSS: "/opt/dateien/neon.css"
    darkBackground: "#070b12"
userDefaults:
  ui:
    darkMode: true
    themeColor: "#22d3ee"
    locale: "de"
  account:
    permissions:
      share: false
http:
  port: 8081
  listen: "127.0.0.1"
  baseURL: "/"
  externalUrl: "https://dateien.kjellh.de"
  trustProxyHeaders: true
EOF
umask 022
echo "[dateien] FileBrowser Quantum wird gestartet (Benutzer aus der App-Konfiguration)."

# An Home Assistant melden: Belegung des Sticks alle 5 Min., Anmeldungen sofort
HA=http://supervisor/core/api
ha_post() {
    curl -s -m 10 -o /dev/null -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN:-}" \
        -H "Content-Type: application/json" -d "$2" "$HA/$1"
}
. /gaeste.sh
. /aktivitaet.sh

# Alle Werte an Home Assistant (alle 5 Min. und auf Zuruf, z. B. nach einem HA-Neustart)
alles_melden() {
    local pfad sensor titel total used avail
    while IFS=$'\t' read -r pfad sensor titel; do
        read -r total used avail <<<"$(df -B1 --output=size,used,avail "$pfad" | tail -1)"
        if [ -n "${total:-}" ] && [ "$total" -gt 0 ]; then
            ha_post "states/$sensor" "$(jq -n --argjson t "$total" --argjson u "$used" --argjson a "$avail" --arg n "Dateien: $titel belegt" '{
                state: (($u * 1000 / $t | floor) / 10),
                attributes: {unit_of_measurement: "%", friendly_name: $n, icon: "mdi:usb-flash-drive",
                    belegt_gb: (($u / 1e8 | floor) / 10), frei_gb: (($a / 1e8 | floor) / 10), gesamt_gb: (($t / 1e8 | floor) / 10)}}')"
        fi
    done < <(jq -r '.[] | [.pfad, .sensor, .titel] | @tsv' "$QUELLEN")
    ordner_melden
    gaeste_melden
    papierkorb_pruefen
    woche_melden
    quantum_update_melden
}

belegung() {
    sleep 20   # Quantum erst starten lassen
    admin_quellen
    while true; do
        gaeste_ablauf_pruefen
        quantum_update_pruefen
        alles_melden
        sleep 300
    done
}
belegung &
BEL_PID=$!

# Logbuch: Aktivitätsprotokoll von Quantum alle 20 s nach neuen Einträgen durchsehen
logbuch_schleife() {
    sleep 30
    while true; do
        aktivitaet_pruefen
        sleep 20
    done
}
logbuch_schleife &
LOG_PID=$!

# Quantum schreibt jede Anfrage als Zeile: METHODE | STATUS | IP | BENUTZER | DAUER | "PFAD"
benutzer_aus() {
    printf '%s' "$1" | sed -n 's/.*username=\([^"&]*\).*/\1/p' | head -c 64
}
watch_log() {
    while IFS= read -r line; do
        echo "$line"
        case "$line" in
            *"POST "*"| 200 |"*'"/api/auth/login'*)
                ha_post events/dateien_anmeldung "$(jq -n --arg b "$(benutzer_aus "$line")" '{benutzer: $b}')"
                gast_anmeldung_pruefen "$(benutzer_aus "$line")" ;;
            *"POST "*"| 403 |"*'"/api/auth/login'*)
                # richtiges Einmal-Passwort, Gast muss jetzt ein eigenes festlegen
                gast_anmeldung_pruefen "$(benutzer_aus "$line")" ;;
            *"POST "*"| 401 |"*'"/api/auth/login'*|*"POST "*"| 429 |"*'"/api/auth/login'*)
                ha_post events/dateien_login_fehlgeschlagen "$(jq -n --arg b "$(benutzer_aus "$line")" '{benutzer: $b}')"
                logbuch "Falsches Passwort für „$(benutzer_aus "$line")“"
                woche_zaehlen fehlversuche ;;
        esac
    done
}

# Quantum nur intern (127.0.0.1:8081); nach außen (Tunnel, Port 8080) lauscht nginx mit der Papierkorb-Weiche
DATEIEN_QUELLEN="$QUELLEN" DATEIEN_ADMIN_USER="$USER_NAME" DATEIEN_ADMIN_PW="$USER_PW" \
    python3 -I /opt/dateien/papierkorb_weiche.py 8082 8081 &
WEICHE_PID=$!
nginx -c /etc/dateien-nginx.conf -g 'daemon on;' || { echo "[dateien] nginx startet nicht."; exit 1; }

filebrowser -c "$CONF" > >(watch_log) 2>&1 &
FB_PID=$!

# Befehle aus Home Assistant (Gäste anlegen/löschen), eine JSON-Zeile je Befehl
while kill -0 "$FB_PID" 2>/dev/null; do
    if read -r -t 5 zeile; then
        befehl_ausfuehren "$zeile"
    elif [ $? -le 128 ]; then
        sleep 5   # stdin zu (kein Home Assistant angebunden)
    fi
done
wait "$FB_PID"
kill "$BEL_PID" "$LOG_PID" 2>/dev/null

#!/bin/bash
# Datei-Manager (File Browser) nur für den USB-Stick. Benutzer und Passwort kommen aus der
# App-Konfiguration (setzt Kjell selbst) und werden nie ins Protokoll geschrieben.
set -u

OPT=/data/options.json
DB=/data/filebrowser.db
MNT=/mnt/stick

LABEL=$(jq -r '.stick_label' "$OPT")
USER_NAME=$(jq -r '.username' "$OPT")
USER_PW=$(jq -r '.password' "$OPT")

if [ -z "$USER_NAME" ] || [ "${#USER_PW}" -lt 12 ]; then
    echo "[dateien] Bitte zuerst in der App-Konfiguration einen Benutzernamen und ein Passwort (mindestens 12 Zeichen) eintragen."
    exit 1
fi

# Stick per Name (Label) suchen, sonst /dev/sda1
DEV=$(blkid -L "$LABEL" 2>/dev/null || true)
[ -n "$DEV" ] || DEV=/dev/sda1
if [ ! -b "$DEV" ]; then
    echo "[dateien] USB-Stick „$LABEL“ nicht gefunden. Steckt er im Home-Assistant-Pi?"
    exit 1
fi

mkdir -p "$MNT"
if ! mountpoint -q "$MNT"; then
    if ! mount -o rw,nosuid,nodev,noexec,uid=0,gid=0,umask=0022,iocharset=utf8 "$DEV" "$MNT"; then
        echo "[dateien] Stick konnte nicht eingebunden werden ($DEV)."
        exit 1
    fi
fi
echo "[dateien] Stick eingebunden: $DEV -> $MNT"

cleanup() {
    kill "${FB_PID:-0}" 2>/dev/null
    wait "${FB_PID:-0}" 2>/dev/null
    sync
    umount "$MNT" 2>/dev/null
    exit 0
}
trap cleanup TERM INT

FB="filebrowser --database $DB"
if [ ! -f "$DB" ]; then
    $FB config init >/dev/null
fi
# Nur der Stick, keine Selbstregistrierung, keine Befehle/Shell, deutsche Oberfläche
$FB config set --root "$MNT" --address 0.0.0.0 --port 8080 --baseURL "" \
    --signup=false --shell "" --branding.name "Dateien" --locale de \
    --minimumPasswordLength 12 >/dev/null

if $FB users ls 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$USER_NAME"; then
    $FB users update "$USER_NAME" --password "$USER_PW" --perm.admin --perm.execute=false >/dev/null
else
    $FB users add "$USER_NAME" "$USER_PW" --perm.admin --perm.execute=false --locale de >/dev/null
fi
# Andere Benutzer (z. B. Standard-Admin) entfernen: nur der eingetragene Benutzer darf rein
for u in $($FB users ls 2>/dev/null | awk 'NR>1 {print $2}'); do
    [ "$u" = "$USER_NAME" ] || $FB users rm "$u" >/dev/null 2>&1
done
echo "[dateien] Benutzer eingerichtet (Name/Passwort aus der Konfiguration)."

$FB &
FB_PID=$!
wait "$FB_PID"

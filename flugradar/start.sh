#!/bin/bash
# Liest die App-Optionen und den Standort aus Home Assistant (nicht im Repo gespeichert)
# und startet dann das ultrafeeder-Image (s6 /init als PID 1).
O=/data/options.json
GAIN=$(jq -r '.gain // "autogain"' $O)
PPM=$(jq -r '.ppm // 0' $O)
LAT=""; LON=""
if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
  CFG=$(curl -s -m 10 -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/api/config)
  LAT=$(echo "$CFG" | jq -r '.latitude // empty'); LON=$(echo "$CFG" | jq -r '.longitude // empty')
  ALT=$(echo "$CFG" | jq -r '.elevation // 0')
fi
export READSB_DEVICE_TYPE=rtlsdr
export READSB_GAIN="$GAIN"
export READSB_RTLSDR_PPM="$PPM"
export READSB_LAT="$LAT" READSB_LON="$LON" READSB_ALT="${ALT:-0}m"
export READSB_RX_LOCATION_ACCURACY=1
export READSB_STATS_RANGE=true
export TAR1090_DEFAULTCENTERLAT="$LAT" TAR1090_DEFAULTCENTERLON="$LON"
export TAR1090_PAGETITLE="Flugradar"
export TAR1090_SITESHOW=true
export TAR1090_ENABLE_AC_DB=true
export UPDATE_TAR1090=false
export TZ="${TZ:-Europe/Berlin}"
echo "Flugradar: Standort $( [ -n "$LAT" ] && echo gesetzt || echo FEHLT ), Gain $GAIN"
/sensoren.sh &
exec /init

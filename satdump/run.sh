#!/bin/bash
# SatDump-Autotrack für Home Assistant: Meteor-M2-3 / M2-4 (LRPT, 137,9 MHz)
set -u

OPT=/data/options.json
OUT=/media/satdump
PASSES="$OUT/passes"
CFG=/data/autotrack.json
mkdir -p "$PASSES"

LAT=$(jq -r '.latitude' "$OPT")
LON=$(jq -r '.longitude' "$OPT")
ALT=$(jq -r '.altitude' "$OPT")
GAIN=$(jq -r '.gain' "$OPT")
MINEL=$(jq -r '.min_elevation' "$OPT")
KEEP=$(jq -r '.keep_days' "$OPT")

if [ "$LAT" = "0" ] || [ "$LAT" = "0.0" ] || [ "$LON" = "0" ] || [ "$LON" = "0.0" ]; then
    echo "[satdump] Bitte zuerst latitude/longitude in der App-Konfiguration eintragen."
    exit 1
fi

jq -n \
  --argjson lat "$LAT" --argjson lon "$LON" --argjson alt "$ALT" \
  --argjson gain "$GAIN" --argjson minel "$MINEL" --arg out "$PASSES" '
{
  parameters: {
    source: "rtlsdr", samplerate: 1.024e6, initial_frequency: 137.9e6,
    gain: $gain, fft_enable: false
  },
  finish_processing: true,
  output_folder: $out,
  qth: { lat: $lat, lon: $lon, alt: $alt },
  http_server: "0.0.0.0:8081",
  tracking: {
    autotrack_cfg: { autotrack_min_elevation: $minel, stop_sdr_when_idle: true, multi_mode: false }
  },
  tracked_objects: [
    { norad: 57166, downlinks: [ { frequency: 137900000, record: false, live: true,
        pipeline_name: "meteor_m2-x_lrpt", pipeline_params: { dc_block: true } } ] },
    { norad: 59051, downlinks: [ { frequency: 137900000, record: false, live: true,
        pipeline_name: "meteor_m2-x_lrpt", pipeline_params: { dc_block: true } } ] }
  ]
}' > "$CFG"

echo "[satdump] Konfiguration geschrieben, Ausgabe nach $PASSES"

# Hintergrund: neuestes Bild als latest.png / latest_ir.png bereitstellen, alte Überflüge löschen
(
  while true; do
    newest() { find "$PASSES" -type f -iname "$1" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-; }
    vis=$(newest '*rgb*MSA*corrected*.png'); [ -z "$vis" ] && vis=$(newest '*rgb*221*corrected*.png')
    [ -z "$vis" ] && vis=$(newest '*rgb*corrected*.png')
    ir=$(newest '*Thermal*corrected*.png'); [ -z "$ir" ] && ir=$(newest 'MSU-MR-5*.png')
    for pair in "latest.png|$vis" "latest_ir.png|$ir"; do
      dst="$OUT/${pair%%|*}"; src="${pair#*|}"
      if [ -n "$src" ] && { [ ! -e "$dst" ] || [ "$src" -nt "$dst" ]; }; then
        cp -f "$src" "$dst.tmp" && mv -f "$dst.tmp" "$dst"
        date -r "$src" -Iseconds > "$OUT/latest_time.txt"
        echo "[satdump] Neues Bild: $src"
      fi
    done
    find "$PASSES" -mindepth 1 -maxdepth 1 -mtime +"$KEEP" -exec rm -rf {} + 2>/dev/null
    sleep 60
  done
) &

cd /data
exec satdump autotrack "$CFG"

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

# SatDump-Einstellungen + Bahndaten (TLE) dauerhaft in /data, damit ein Neustart ohne Internet/CelesTrak-Limit klappt
mkdir -p /data/satdump-config /root/.config
[ -L /root/.config/satdump ] || { rm -rf /root/.config/satdump; ln -s /data/satdump-config /root/.config/satdump; }
TLES=/data/satdump-config/satdump_tles.txt
if ! grep -q "^1 57166" "$TLES" 2>/dev/null || ! grep -q "^1 59051" "$TLES" 2>/dev/null; then
  : > "$TLES.tmp"
  for n in 57166 59051; do
    t=$(curl -s -m 20 "https://celestrak.org/NORAD/elements/gp.php?CATNR=$n&FORMAT=tle" | tr -d '\r')
    if echo "$t" | grep -q "^1 $n"; then echo "$t" >> "$TLES.tmp"; echo "[satdump] Bahndaten für $n geladen"
    else echo "[satdump] Bahndaten für $n nicht ladbar (CelesTrak)"; fi
  done
  [ -s "$TLES.tmp" ] && mv -f "$TLES.tmp" "$TLES" || rm -f "$TLES.tmp"
fi

# Platzhalter, damit die Kamera-Entitäten (local_file) schon vor dem ersten Bild existieren
PLACEHOLDER='iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAIAAAC0SDtlAAAAFElEQVR4nGPgFZEhCTGMahAZDBoAiOQiUQezVScAAAAASUVORK5CYII='
for f in latest.png latest_ir.png gallery_1.png gallery_2.png gallery_3.png gallery_4.png gallery_5.png gallery_6.png; do
  [ -e "$OUT/$f" ] || echo "$PLACEHOLDER" | base64 -d > "$OUT/$f"
done

echo "[satdump] Konfiguration geschrieben, Ausgabe nach $PASSES"

# Status an Home Assistant melden (Sensoren sensor.satdump_*)
ha_state() {  # $1=entity_id  $2=JSON-Body
  [ -n "${SUPERVISOR_TOKEN:-}" ] || return 0
  curl -s -m 10 -o /dev/null -X POST     -H "Authorization: Bearer $SUPERVISOR_TOKEN" -H "Content-Type: application/json"     -d "$2" "http://supervisor/core/api/states/$1"
}

report_status() {
  api=$(curl -s -m 5 http://127.0.0.1:8081/api) || return 0
  [ -n "$api" ] || return 0
  echo "$api" | jq -c '.object_tracker as $t | if (($t.object_name // "None") == "None") or (($t.next_aos_time // 0) <= 0) then {
      state: "unknown", attributes: { friendly_name: "SatDump nächster Überflug", device_class: "timestamp",
        icon: "mdi:satellite-variant", satellit: null, laeuft_gerade: false, hinweis: "keine Bahndaten" } } else {
      state: ($t.next_aos_time | floor | todate),
      attributes: {
        friendly_name: "SatDump nächster Überflug", device_class: "timestamp", icon: "mdi:satellite-variant",
        satellit: $t.object_name, laeuft_gerade: ($t.next_event_is_aos | not),
        ende: ($t.next_los_time | floor | todate),
        elevation_jetzt: ($t.sat_current_pos.el * 10 | round / 10)
      } } end' | { read -r b && ha_state sensor.satdump_naechster_ueberflug "$b"; }
  echo "$api" | jq -c '(.live_pipeline // {}) as $p | ((.object_tracker.next_event_is_aos | not) and ((.object_tracker.next_aos_time // 0) > 0)) as $on | {
      state: (if $on then "Empfang" else "Warten" end),
      attributes: {
        friendly_name: "SatDump Status", icon: (if $on then "mdi:satellite-uplink" else "mdi:satellite-variant" end),
        snr: (($p.psk_demod.snr // 0) * 10 | round / 10),
        snr_spitze: (($p.psk_demod.peak_snr // 0) * 10 | round / 10),
        synchron: ($p.ccsds_conv_concat_decoder.deframer_lock // false)
      } }' | { read -r b && ha_state sensor.satdump_status "$b"; }
  if [ -s "$OUT/latest_time.txt" ]; then
    ha_state sensor.satdump_letztes_bild "$(jq -cn --arg t "$(cat "$OUT/latest_time.txt")"       '{state: $t, attributes: {friendly_name: "SatDump letztes Bild", device_class: "timestamp", icon: "mdi:image-filter-hdr"}}')"
  fi
}

# Hintergrund: neuestes Bild als latest.png / latest_ir.png, Galerie gallery_1..6.png, alte Überflüge löschen
(
  newest() { find "$PASSES" -type f -iname "$1" -printf '%T@ %p
' 2>/dev/null | sort -n | tail -${2:-1} | cut -d' ' -f2-; }
  while true; do
    vis=$(newest '*rgb*MSA*corrected*.png'); [ -z "$vis" ] && vis=$(newest '*rgb*221*corrected*.png')
    [ -z "$vis" ] && vis=$(newest '*rgb*corrected*.png')
    ir=$(newest '*Thermal*corrected*.png'); [ -z "$ir" ] && ir=$(newest 'MSU-MR-5*.png')
    for pair in "latest.png|$vis" "latest_ir.png|$ir"; do
      dst="$OUT/${pair%%|*}"; src="${pair#*|}"
      if [ -n "$src" ] && { [ ! -e "$dst" ] || [ "$src" -nt "$dst" ]; }; then
        cp -f "$src" "$dst.tmp" && mv -f "$dst.tmp" "$dst"
        [ "${pair%%|*}" = "latest.png" ] && date -r "$src" -Iseconds > "$OUT/latest_time.txt"
        echo "[satdump] Neues Bild: $src"
      fi
    done
    # Galerie: je Überflug ein Farbbild (MSA bevorzugt), die neuesten 6, gallery_1 = neuestes
    n=1
    for d in $(find "$PASSES" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f
' | sort -rn | cut -d' ' -f2- | tr ' ' '|'); do
      d="$PASSES/${d//|/ }"
      img=$(find "$d" -type f -iname '*rgb*MSA*corrected*.png' | head -1)
      [ -z "$img" ] && img=$(find "$d" -type f -iname '*rgb*corrected*.png' | head -1)
      [ -z "$img" ] && continue
      dst="$OUT/gallery_$n.png"
      if [ "$(cat "$dst.src" 2>/dev/null)" != "$img" ]; then
        cp -f "$img" "$dst.tmp" && mv -f "$dst.tmp" "$dst" && echo "$img" > "$dst.src"
      fi
      n=$((n+1)); [ $n -gt 6 ] && break
    done
    find "$PASSES" -mindepth 1 -maxdepth 1 -mtime +"$KEEP" -exec rm -rf {} + 2>/dev/null
    for _ in 1 2 3 4; do report_status; sleep 15; done
  done
) &

cd /data
exec satdump autotrack "$CFG"

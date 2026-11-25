#!/bin/bash
# Schreibt alle 10 s Sensoren nach Home Assistant und löst bei besonderen Fliegern
# das Ereignis "flugradar_besonders" aus (je Flieger höchstens alle 60 Minuten).
O=/data/options.json
UM=$(jq -r '.umkreis_km // 10' $O); TIEF=$(jq -r '.tief_m // 600' $O)
declare -A GEMELDET
post() { curl -s -m 8 -o /dev/null -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  -H "Content-Type: application/json" -d "$2" "http://supervisor/core/api/$1"; }
sleep 40
while true; do
  F=/run/readsb/aircraft.json
  if [ -n "${SUPERVISOR_TOKEN:-}" ] && [ -s "$F" ]; then
    J=$(jq --argjson um "$UM" --argjson tief "$TIEF" '
      def km: (. * 1.852 * 10 | round) / 10;
      [.aircraft[] | select(.lat != null and .r_dst != null)
        | {hex, cs: ((.flight // "") | gsub(" ";"")), reg: (.r // ""), typ: (.t // ""), desc: (.desc // ""),
           hoehe_m: (if (.alt_baro|type)=="number" then (.alt_baro*0.3048|round) else 0 end),
           boden: (.alt_baro == "ground"),
           km: (.r_dst|km), richtung: ((.r_dir // 0)|round), kmh: (((.gs // 0)*1.852)|round),
           squawk: (.squawk // ""), mil: (((.dbFlags // 0) % 2) == 1)}]
      | sort_by(.km) as $a
      | {anzahl: ($a|length), nah: [$a[] | select(.km <= $um)], liste: $a[0:8],
         besonders: [$a[] | select(((.squawk=="7500") or (.squawk=="7600") or (.squawk=="7700")) or ((.boden|not) and (
             ((.cs|test("^CHX")) or .squawk=="0020") or
             (.mil and .km <= 30) or
             (.hoehe_m > 0 and .hoehe_m < $tief and .km <= 3))))
           | . + {grund: (if (.squawk=="7500" or .squawk=="7600" or .squawk=="7700") then "notfall"
                          elif ((.cs|test("^CHX")) or .squawk=="0020") then "rettung"
                          elif .mil then "militaer" else "tief" end)}]}' "$F" 2>/dev/null)
    if [ -n "$J" ]; then
      ANZ=$(echo "$J" | jq '.anzahl'); NAH=$(echo "$J" | jq '.nah|length')
      post states/sensor.flugradar_flugzeuge "$(echo "$J" | jq -c '{state: .anzahl, attributes: {friendly_name: "Flugradar Flugzeuge", unit_of_measurement: "Flugzeuge", icon: "mdi:airplane", liste: .liste}}')"
      post states/sensor.flugradar_ueber_mir "$(echo "$J" | jq -c --argjson um "$UM" '{state: (.nah|length), attributes: {friendly_name: "Flugradar über mir", unit_of_measurement: "Flugzeuge", icon: "mdi:airplane-marker", umkreis_km: $um, liste: .nah[0:8]}}')"
      post states/sensor.flugradar_naechster "$(echo "$J" | jq -c '(.liste[0] // {}) as $n | {state: (if $n.hex then (if $n.cs != "" then $n.cs else ($n.reg // $n.hex) end) else "keiner" end), attributes: ($n + {friendly_name: "Flugradar nächster Flieger", icon: "mdi:airplane-clock"})}')"
      NOW=$(date +%s)
      while read -r b; do
        [ -z "$b" ] && continue
        HEX=$(echo "$b" | jq -r '.hex'); LAST=${GEMELDET[$HEX]:-0}
        if [ $((NOW - LAST)) -ge 3600 ]; then GEMELDET[$HEX]=$NOW; post events/flugradar_besonders "$b"; fi
      done < <(echo "$J" | jq -c '.besonders[]')
    fi
  fi
  sleep 10
done

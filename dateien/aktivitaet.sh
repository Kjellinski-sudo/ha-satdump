# Logbuch, Wochenzahlen und Papierkorb für den Datei-Manager (wird von run.sh eingebunden).
# Quelle ist das Aktivitätsprotokoll von Quantum (Tabelle activity_log, nur lesend geöffnet).

FBDB=/data/quantum/filebrowser.sqlite
LETZTE_ID=/data/aktivitaet_letzte_id
WOCHE=/data/woche.json
PAPIERKORB_DIR="Papierkorb"
PAPIERKORB_LISTE=/data/papierkorb.json
PAPIERKORB_TAGE=7

silent_an() {
    curl -s -m 5 -H "Authorization: Bearer ${SUPERVISOR_TOKEN:-}" "$HA/states/input_boolean.silent_modus" | jq -e '.state == "on"' >/dev/null 2>&1
}

logbuch() {
    ha_post services/logbook/log "$(jq -n --arg m "$1" '{name: "Dateien", message: $m, entity_id: "sensor.dateien_letzte_aktion"}')"
    ha_post states/sensor.dateien_letzte_aktion "$(jq -n --arg m "${1:0:250}" --arg z "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{state: $m, attributes: {friendly_name: "Dateien: letzte Aktion", icon: "mdi:history", zeit: $z}}')"
}

# Zähler der laufenden Kalenderwoche (Montag–Sonntag)
woche_zaehlen() {
    local feld=$1 anzahl=${2:-1} kw
    kw=$(date +%G-W%V)
    (
        flock 9
        [ -f "$WOCHE" ] || echo '{}' > "$WOCHE"
        jq --arg kw "$kw" --arg f "$feld" --argjson n "$anzahl" '
            (if .woche != $kw then {woche: $kw, hochgeladen: 0, heruntergeladen: 0, geloescht: 0, verschoben: 0, anmeldungen: 0, fehlversuche: 0} else . end)
            | .[$f] = ((.[$f] // 0) + $n)' "$WOCHE" > "$WOCHE.neu" && mv "$WOCHE.neu" "$WOCHE"
    ) 9>"$LOCK"
}

woche_melden() {
    local kw
    kw=$(date +%G-W%V)
    [ -f "$WOCHE" ] || echo '{}' > "$WOCHE"
    ha_post states/sensor.dateien_woche "$(jq --arg kw "$kw" '
        (if .woche != $kw then {woche: $kw, hochgeladen: 0, heruntergeladen: 0, geloescht: 0, verschoben: 0, anmeldungen: 0, fehlversuche: 0} else . end)
        | {state: ((.hochgeladen // 0) + (.heruntergeladen // 0) + (.geloescht // 0) + (.verschoben // 0)),
           attributes: (. + {friendly_name: "Dateien: Aktionen diese Woche", icon: "mdi:calendar-week", unit_of_measurement: "Aktionen"})}' "$WOCHE")"
}

pfade() { jq -r '[(.details | fromjson? | .paths // empty)[]?] as $p | if ($p|length) > 0 then ($p | map(ltrimstr("/")) | .[0:3] | join(", ")) + (if ($p|length) > 3 then " und \(($p|length) - 3) weitere" else "" end) else (.path // "" | ltrimstr("/")) end'; }

aktivitaet_pruefen() {
    [ -f "$FBDB" ] || return
    local letzte zeilen
    letzte=$(cat "$LETZTE_ID" 2>/dev/null || echo "")
    if ! [[ "$letzte" =~ ^[0-9]+$ ]]; then
        # Erststart: nur neue Einträge melden
        letzte=$(sqlite3 -readonly "$FBDB" 'select coalesce(max(id),0) from activity_log' 2>/dev/null || echo 0)
        echo "$letzte" > "$LETZTE_ID"
        return
    fi
    zeilen=$(sqlite3 -readonly -json "$FBDB" "select a.id, a.created_at, coalesce(u.username, '?') as benutzer, a.event_type as typ,
        coalesce(a.path,'') as path, coalesce(a.target_path,'') as target, coalesce(a.details,'{}') as details, a.success
        from activity_log a left join users u on u.user_id = a.user_id where a.id > $letzte order by a.id limit 200" 2>/dev/null)
    [ -n "$zeilen" ] || return
    local zeile id benutzer typ was ziel n
    declare -A gast_hoch=()
    while IFS= read -r zeile; do
        id=$(jq -r .id <<<"$zeile"); benutzer=$(jq -r .benutzer <<<"$zeile"); typ=$(jq -r .typ <<<"$zeile")
        was=$(pfade <<<"$zeile"); ziel=$(jq -r '.target | ltrimstr("/")' <<<"$zeile")
        n=$(jq -r '(.details | fromjson? | .fileCount) // 1' <<<"$zeile")
        case "$typ" in
            login)       logbuch "$benutzer hat sich angemeldet"; woche_zaehlen anmeldungen ;;
            logout)      ;;
            upload)      logbuch "$benutzer hat „$was“ hochgeladen"; woche_zaehlen hochgeladen
                         jq -e --arg b "$benutzer" 'any(.[]; .benutzer == $b)' "$GAESTE" >/dev/null 2>&1 && gast_hoch[$benutzer]=$(( ${gast_hoch[$benutzer]:-0} + 1 )) ;;
            download)    logbuch "$benutzer hat „$was“ heruntergeladen"; woche_zaehlen heruntergeladen "$n" ;;
            move|rename) if [[ "$ziel" == "$PAPIERKORB_DIR"/* ]]; then logbuch "$benutzer hat „$was“ in den Papierkorb gelegt"
                         else logbuch "$benutzer hat „$was“ nach „$ziel“ verschoben/umbenannt"; fi
                         woche_zaehlen verschoben ;;
            copy)        logbuch "$benutzer hat „$was“ nach „$ziel“ kopiert" ;;
            delete|bulkDelete) logbuch "$benutzer hat „$was“ endgültig gelöscht"; woche_zaehlen geloescht "$n" ;;
            userCreate|userUpdate|userDelete) ;;   # Gäste meldet gaeste.sh selbst
            *)           logbuch "$benutzer: $typ ${was:+„$was“}" ;;
        esac
        echo "$id" > "$LETZTE_ID"
    done < <(jq -c '.[]' <<<"$zeilen")
    woche_melden
    # Gäste, die etwas hochgeladen haben: eine Push je Durchlauf (nicht im Silent-Modus)
    local b name
    for b in "${!gast_hoch[@]}"; do
        silent_an && continue
        name=$(jq -r --arg b "$b" 'first(.[] | select(.benutzer == $b) | .name) // $b' "$GAESTE")
        push "Dateien: $name hat etwas hochgeladen" "$name hat ${gast_hoch[$b]} Datei(en) hochgeladen. Details im Logbuch."
    done
}

# Papierkorb: Ordner „Papierkorb“ auf dem Stick; was darin liegt, wird nach 7 Tagen endgültig gelöscht.
# Gezählt wird ab dem Zeitpunkt, an dem die App den Eintrag zum ersten Mal im Papierkorb sieht.
papierkorb_pruefen() {
    local dir="$MNT/$PAPIERKORB_DIR" jetzt eintraege
    mkdir -p "$dir"
    [ -f "$PAPIERKORB_LISTE" ] || echo '{}' > "$PAPIERKORB_LISTE"
    jetzt=$(date +%s)
    eintraege=$(find "$dir" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | jq -R . | jq -s .)
    jq --argjson e "$eintraege" --argjson j "$jetzt" \
        'with_entries(select(.key as $k | $e | index($k))) as $alt | reduce $e[] as $k ($alt; .[$k] //= $j)' \
        "$PAPIERKORB_LISTE" > "$PAPIERKORB_LISTE.neu" && mv "$PAPIERKORB_LISTE.neu" "$PAPIERKORB_LISTE"
    local name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        case "$name" in */*|.|..) continue ;; esac
        rm -rf -- "$dir/$name" && logbuch "Papierkorb: „$name“ nach $PAPIERKORB_TAGE Tagen endgültig gelöscht"
    done < <(jq -r --argjson g $((jetzt - PAPIERKORB_TAGE * 86400)) 'to_entries[] | select(.value <= $g) | .key' "$PAPIERKORB_LISTE")
    jq --argjson g $((jetzt - PAPIERKORB_TAGE * 86400)) 'with_entries(select(.value > $g))' "$PAPIERKORB_LISTE" \
        > "$PAPIERKORB_LISTE.neu" && mv "$PAPIERKORB_LISTE.neu" "$PAPIERKORB_LISTE"
    ha_post states/sensor.dateien_papierkorb "$(jq --argjson j "$jetzt" --argjson t "$PAPIERKORB_TAGE" '{state: length, attributes: {
        friendly_name: "Dateien: Papierkorb", icon: "mdi:delete-clock", unit_of_measurement: "Einträge",
        eintraege: [to_entries[] | {name: .key, loeschen_am: ((.value + $t * 86400) | strftime("%Y-%m-%dT%H:%M:%SZ"))}]}}' "$PAPIERKORB_LISTE")"
}

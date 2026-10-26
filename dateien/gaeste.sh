# Gästeverwaltung für den Datei-Manager (wird von run.sh eingebunden).
# Befehle kommen als JSON-Zeile über stdin (Home Assistant: hassio.addon_stdin).
# Gast-Passwörter werden nur erzeugt, an Quantum übergeben und per Push an Kjell geschickt –
# nie ins Protokoll, nie in eine Datei.

FBURL=http://127.0.0.1:8081
GAESTE=/data/gaeste.json
LOCK=/tmp/gaeste.lock
LINK=https://dateien.kjellh.de

[ -f "$GAESTE" ] || echo '[]' > "$GAESTE"

uri() { jq -rn --arg v "$1" '$v|@uri'; }

# Name -> Benutzername: klein, Umlaute umschreiben, nur a-z 0-9 _ -
benutzername() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
        | sed 's/ä/ae/g; s/ö/oe/g; s/ü/ue/g; s/ß/ss/g; s/Ä/ae/g; s/Ö/oe/g; s/Ü/ue/g; s/ /_/g' \
        | tr -cd 'a-z0-9_-' | head -c 32
}

# 16 Zeichen in Vierergruppen, ohne verwechselbare Zeichen (0/O, 1/l/I)
zufallspasswort() {
    local roh
    roh=$(LC_ALL=C tr -dc 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789' </dev/urandom | head -c 16)
    printf '%s-%s-%s-%s' "${roh:0:4}" "${roh:4:4}" "${roh:8:4}" "${roh:12:4}"
}

admin_token() {
    curl -s -m 10 -X POST "$FBURL/api/auth/login?username=$(uri "$USER_NAME")" -H "X-Password: $(uri "$USER_PW")"
}

# fb_api METHODE PFAD [JSON über stdin] -> HTTP-Status; Antwort in /tmp/fb_api.out
fb_api() {
    local tok=$1 m=$2 p=$3
    if [ $# -ge 4 ]; then
        printf '%s' "$4" | curl -s -m 15 -o /tmp/fb_api.out -w '%{http_code}' -X "$m" "$FBURL$p" \
            -H "Authorization: Bearer $tok" -H "X-Password: $(uri "$USER_PW")" \
            -H "Content-Type: application/json" --data-binary @-
    else
        curl -s -m 15 -o /tmp/fb_api.out -w '%{http_code}' -X "$m" "$FBURL$p" \
            -H "Authorization: Bearer $tok" -H "X-Password: $(uri "$USER_PW")"
    fi
}

# Push direkt über die HA-API (keine Automation, also kein Trace mit dem Passwort)
push() {
    ha_post "services/notify/$PUSH_DIENST" "$(jq -n --arg t "$1" --arg m "$2" --arg tag "dateien_gast_$(date +%s%N)" \
        '{title: $t, message: $m, data: {tag: $tag, url: "https://dateien.kjellh.de"}}')"
}

# Ordner der obersten Ebene beider Sticks; die vom zweiten Stick mit „Stick 2/“ davor
ordner_melden() {
    local liste liste2='[]' zwei=false
    liste=$(find "$MNT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name 'System Volume Information' ! -name 'Papierkorb' -printf '%f\n' 2>/dev/null | sort | jq -R . | jq -s .)
    if mountpoint -q "$MNT2" 2>/dev/null; then
        zwei=true
        liste2=$(find "$MNT2" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name 'System Volume Information' ! -name 'Papierkorb' -printf 'Stick 2/%f\n' 2>/dev/null | sort | jq -R . | jq -s .)
    fi
    ha_post states/sensor.dateien_ordner "$(jq -n --argjson o "$liste" --argjson o2 "$liste2" --argjson z "$zwei" '{state: (($o + $o2)|length),
        attributes: {ordner: ($o + $o2), stick2: $z, friendly_name: "Dateien: Ordner auf den Sticks", icon: "mdi:folder-multiple"}}')"
}

gaeste_melden() {
    ha_post states/sensor.dateien_gaeste "$(jq '{state: length, attributes: {
        friendly_name: "Dateien: Gäste", icon: "mdi:account-multiple",
        gaeste: [ .[] | {name, benutzer, recht, ordner, email,
                  bis: (if .bis > 0 then (.bis | strftime("%Y-%m-%dT%H:%M:%SZ")) else null end),
                  erste_anmeldung: (if .erste_anmeldung then (.erste_anmeldung | strftime("%Y-%m-%dT%H:%M:%SZ")) else null end)} ]}}' "$GAESTE")"
}

gast_anlegen() {
    local cmd=$1 name benutzer tage ordner recht modus email scope perms pw tok code bis jetzt rp lp hinweis
    name=$(jq -r '.name // ""' <<<"$cmd" | head -c 40)
    benutzer=$(benutzername "$name")
    tage=$(jq -r '.tage // 7' <<<"$cmd"); [[ "$tage" =~ ^[0-9]+$ ]] || tage=7
    ordner=$(jq -r '.ordner // ""' <<<"$cmd")
    recht=$(jq -r '.recht // "ansehen"' <<<"$cmd")
    modus=$(jq -r '.passwort // "einmalig"' <<<"$cmd")
    email=$(jq -r '.email // ""' <<<"$cmd" | head -c 100)

    if [ "${#benutzer}" -lt 2 ]; then push "Dateien: Gast nicht angelegt" "Bitte einen Namen mit mindestens 2 Buchstaben eingeben."; return; fi
    if [ "$benutzer" = "$(benutzername "$USER_NAME")" ] || jq -e --arg b "$benutzer" 'any(.[]; .benutzer == $b)' "$GAESTE" >/dev/null; then
        push "Dateien: Gast nicht angelegt" "Den Benutzer „$benutzer“ gibt es schon. Bitte einen anderen Namen wählen oder den alten Gast zuerst löschen."; return
    fi

    # Zugriff planen: Liste aus „Fotos“, „Stick 2/Bilder“, __neu__/__neu2__ (neuer Gast-Ordner), __alles__/__alles2__ (ganzer Stick).
    # Ergebnis je Speicher: {quelle, alles, ordner: [...]}
    local liste plan='[]' eintrag q o wurzel anzeige perms
    liste=$(jq -c 'if (.ordner | type) == "array" then .ordner elif (.ordner // "") == "" then ["__alles__"] else [.ordner] end' <<<"$cmd")
    [ "$(jq 'length' <<<"$liste")" -gt 0 ] || liste='["__neu__"]'
    while IFS= read -r eintrag; do
        q="Stick"; wurzel="$MNT"; o="$eintrag"
        case "$o" in
            "Stick 2/"*|__neu2__|__alles2__)
                if ! mountpoint -q "$MNT2" 2>/dev/null; then push "Dateien: Gast nicht angelegt" "Stick 2 ist gerade nicht eingesteckt."; return; fi
                q="Stick 2"; wurzel="$MNT2"; o=${o#Stick 2/}
                case "$o" in __neu2__) o=__neu__ ;; __alles2__) o=__alles__ ;; esac ;;
        esac
        case "$o" in
            __alles__|""|/)
                plan=$(jq --arg q "$q" 'if any(.[]; .quelle == $q) then map(if .quelle == $q then .alles = true else . end)
                    else . + [{quelle: $q, alles: true, ordner: []}] end' <<<"$plan")
                continue ;;
            __neu__) o=$(printf 'Gast-%s' "$name" | tr -d '/\\' | head -c 60); mkdir -p "$wurzel/$o" ;;
            *) if [[ "$o" == */* || "$o" == .* || "$o" == Papierkorb || ! -d "$wurzel/$o" ]]; then
                   push "Dateien: Gast nicht angelegt" "Der Ordner „$o“ wurde auf $q nicht gefunden."; return
               fi ;;
        esac
        plan=$(jq --arg q "$q" --arg o "$o" 'if any(.[]; .quelle == $q) then map(if .quelle == $q then .ordner = (.ordner + [$o] | unique) else . end)
            else . + [{quelle: $q, alles: false, ordner: [$o]}] end' <<<"$plan")
    done < <(jq -r '.[]' <<<"$liste")
    # Ganzer Stick schlägt einzelne Ordner auf demselben Stick
    plan=$(jq 'map(if .alles then .ordner = [] else . end)' <<<"$plan")
    # Briefkasten sieht keine Ordner, kann also nur in genau einen Ordner (bzw. einen ganzen Stick) einwerfen
    if [ "$recht" = briefkasten ] && [ "$(jq '[.[] | if .alles then 1 else (.ordner | length) end] | add' <<<"$plan")" -gt 1 ]; then
        push "Dateien: Gast nicht angelegt" "Ein Briefkasten-Gast kann nur einen Ordner bekommen. Bitte genau einen auswählen."; return
    fi
    # Anzeige: „Fotos, Stick 2/Bilder“ bzw. „Ganzer Stick“
    anzeige=$(jq -r '[.[] | . as $e | if .alles then "Ganzer " + .quelle
        else (.ordner[] | if $e.quelle == "Stick" then . else $e.quelle + "/" + . end) end] | join(", ")' <<<"$plan")
    case "$recht" in
        laden|hochladen) recht=laden
                     perms='{"view":true,"download":true,"modify":false,"delete":false,"create":true,"configured":true}' ;;
        alles)       perms='{"view":true,"download":true,"modify":true,"delete":true,"create":true,"configured":true}' ;;
        briefkasten) perms='{"view":false,"download":false,"modify":false,"delete":false,"create":true,"configured":true}' ;;
        *) recht=ansehen; perms='{"view":true,"download":false,"modify":false,"delete":false,"create":false,"configured":true}' ;;
    esac
    case "$modus" in
        dauerhaft) rp=false; lp=true ;;
        selbst)    rp=false; lp=false ;;
        *) modus=einmalig; rp=true; lp=false ;;
    esac

    if [ "$modus" != selbst ] && [ "${PW_PUSH:-false}" != true ]; then
        push "Dateien: Gast nicht angelegt" "Zufallspasswörter per Push sind noch nicht freigeschaltet (erst nach dem Home-Assistant-Neustart). Bitte vorerst „Selbst festlegen“ wählen."; return
    fi
    tok=$(admin_token)
    pw=$(zufallspasswort)
    code=$(fb_api "$tok" POST /api/users "$(jq -n --arg u "$benutzer" --arg p "$pw" '{which: [], data: {username: $u, password: $p,
        loginMethod: "password", permissions: {admin: false, api: false, share: false, realtime: false}}}')")
    if [ "$code" != 201 ]; then
        echo "[dateien] Gast anlegen fehlgeschlagen (HTTP $code)."
        push "Dateien: Gast nicht angelegt" "Der Datei-Manager hat das Anlegen abgelehnt (Fehler $code)."; return
    fi
    # Speicher: ganzer Stick bzw. ein Ordner -> Startordner; mehrere Ordner -> Start „/“ plus Zugriffsregeln
    local scopes
    scopes=$(jq --argjson perm "$perms" 'map({name: .quelle, permissions: $perm,
        scope: (if .alles then "/" elif (.ordner | length) == 1 then "/" + .ordner[0] else "/" end)})' <<<"$plan")
    code=$(fb_api "$tok" PATCH "/api/users?username=$(uri "$benutzer")" "$(jq -n --arg u "$benutzer" --argjson sc "$scopes" \
        --argjson rp "$rp" --argjson lp "$lp" '{which: ["scopes","requirePasswordChange","lockPassword"],
        data: {username: $u, requirePasswordChange: $rp, lockPassword: $lp, scopes: $sc}}')")
    local ok=true
    [ "$code" = 204 ] || [ "$code" = 200 ] || ok=false
    if [ "$ok" = true ]; then
        while IFS=$'\t' read -r q o; do
            [ "$(regel_setzen "$tok" "$q" "$o" "$benutzer")" = 200 ] || ok=false
        done < <(jq -r '.[] | select((.alles | not) and (.ordner | length) > 1) | (.quelle as $q | ([$q, "/"], (.ordner[] | [$q, "/" + .])) | @tsv)' <<<"$plan")
    fi
    # Gegenprobe: Speicher, Startordner, Rechte und Zugriffsregeln genau wie geplant – sonst Gast sofort wieder weg
    if [ "$ok" = true ]; then
        fb_api "$tok" GET "/api/users?username=$(uri "$benutzer")" >/dev/null
        jq -e --argjson sc "$scopes" '([.scopes[] | {name, scope}] | sort_by(.name)) == ([$sc[] | {name, scope}] | sort_by(.name))
            and (.permissions.admin | not) and (.permissions.share | not)
            and all(.scopes[]; (.permissions | {view, download, modify, delete, create}) == ($sc[0].permissions | {view, download, modify, delete, create}))' \
            /tmp/fb_api.out >/dev/null 2>&1 || ok=false
    fi
    if [ "$ok" = true ]; then
        while IFS= read -r q; do
            fb_api "$tok" GET "/api/access?source=$(uri "$q")" >/dev/null
            jq -e --arg b "$benutzer" --argjson e "$(jq --arg q "$q" '[.[] | select(.quelle == $q) | .ordner[]] | sort' <<<"$plan")" '
                (to_entries | map(select(.value.allow.users | index($b))) | map(.key | ltrimstr("/") | rtrimstr("/")) | sort) == $e
                and ((.["/"].deny.users // []) | index($b)) != null' /tmp/fb_api.out >/dev/null 2>&1 || ok=false
        done < <(jq -r '.[] | select((.alles | not) and (.ordner | length) > 1) | .quelle' <<<"$plan")
    fi
    if [ "$ok" != true ]; then
        regeln_entfernen "$tok" "$benutzer"
        fb_api "$tok" DELETE "/api/users?username=$(uri "$benutzer")" >/dev/null
        echo "[dateien] Gast-Rechte ließen sich nicht sicher setzen (HTTP $code), Gast wieder entfernt."
        push "Dateien: Gast nicht angelegt" "Die Rechte ließen sich nicht sicher auf die gewählten Ordner begrenzen. Der Gast wurde wieder entfernt."; return
    fi

    jetzt=$(date +%s)
    if [ "$tage" -gt 0 ]; then bis=$((jetzt + tage * 86400)); else bis=0; fi
    (
        flock 9
        jq --arg n "$name" --arg b "$benutzer" --arg r "$recht" --arg o "$anzeige" --arg e "$email" \
           --argjson bis "$bis" --argjson j "$jetzt" \
           --argjson z "$plan" '. + [{name: $n, benutzer: $b, recht: $r, ordner: $o, zugriff: $z, email: $e, bis: $bis, angelegt: $j, erste_anmeldung: null}]' \
           "$GAESTE" > "$GAESTE.neu" && mv "$GAESTE.neu" "$GAESTE"
    ) 9>"$LOCK"
    gaeste_melden
    ordner_melden
    echo "[dateien] Gast „$benutzer“ angelegt ($recht, $anzeige, $tage Tage)."
    logbuch "Gast $name ($benutzer) angelegt: $recht, Ordner $anzeige, $([ "$tage" -gt 0 ] && echo "$tage Tage" || echo unbegrenzt)"

    case "$recht" in
        ansehen) hinweis="nur ansehen (Vorschau), kein Herunterladen" ;;
        laden) hinweis="ansehen, herunterladen und hochladen" ;;
        alles) hinweis="alles: ansehen, herunter-/hochladen, umbenennen, Ordner anlegen, löschen (in den Papierkorb)" ;;
        briefkasten) hinweis="Briefkasten: nur einwerfen (Menü > Datei-Aktionen > Hochladen), nichts sehen" ;;
    esac
    local gueltig="unbegrenzt"
    [ "$bis" -gt 0 ] && gueltig="bis $(TZ=Europe/Berlin date -d "@$bis" '+%d.%m.%Y %H:%M')"
    local cf="Cloudflare: E-Mail des Gastes in die Regel „Gäste“ eintragen."
    [ -n "$email" ] && cf="Cloudflare: $email in die Regel „Gäste“ eintragen."
    case "$modus" in
        einmalig)  push "Dateien: Gast $name angelegt" "Benutzer: $benutzer
Einmal-Passwort: $pw
(muss beim ersten Login geändert werden)
Ordner: $anzeige · $hinweis
Gültig: $gueltig
$LINK
$cf" ;;
        dauerhaft) push "Dateien: Gast $name angelegt" "Benutzer: $benutzer
Passwort: $pw
Ordner: $anzeige · $hinweis
Gültig: $gueltig
$LINK
$cf" ;;
        selbst)    push "Dateien: Gast $name angelegt" "Benutzer: $benutzer
Passwort bitte selbst setzen: im Datei-Manager Einstellungen > Benutzerverwaltung > $benutzer.
Ordner: $anzeige · $hinweis
Gültig: $gueltig
$cf" ;;
    esac
    pw=""
    ha_post events/dateien_gast_angelegt "$(jq -n --arg b "$benutzer" --arg r "$recht" --arg o "$anzeige" '{benutzer: $b, recht: $r, ordner: $o}')"
}

# gast_entfernen BENUTZER GRUND(geloescht|abgelaufen)
gast_entfernen() {
    local benutzer=$1 grund=$2 tok code eintrag email name
    eintrag=$(jq -c --arg b "$benutzer" 'first(.[] | select(.benutzer == $b)) // empty' "$GAESTE")
    [ -n "$eintrag" ] || { echo "[dateien] Gast „$benutzer“ unbekannt."; return; }
    name=$(jq -r .name <<<"$eintrag"); email=$(jq -r .email <<<"$eintrag")
    tok=$(admin_token)
    regeln_entfernen "$tok" "$benutzer"
    code=$(fb_api "$tok" DELETE "/api/users?username=$(uri "$benutzer")")
    if [ "$code" != 200 ] && [ "$code" != 204 ] && [ "$code" != 404 ]; then
        echo "[dateien] Gast löschen fehlgeschlagen (HTTP $code)."
        push "Dateien: Gast nicht gelöscht" "Gast $name konnte nicht gelöscht werden (Fehler $code). Ich versuche es in 5 Minuten erneut."; return
    fi
    (
        flock 9
        jq --arg b "$benutzer" 'map(select(.benutzer != $b))' "$GAESTE" > "$GAESTE.neu" && mv "$GAESTE.neu" "$GAESTE"
    ) 9>"$LOCK"
    gaeste_melden
    echo "[dateien] Gast „$benutzer“ entfernt ($grund)."
    logbuch "Gast $name ($benutzer) $([ "$grund" = abgelaufen ] && echo "abgelaufen und gelöscht" || echo gelöscht)"
    local was="gelöscht"; [ "$grund" = abgelaufen ] && was="ist abgelaufen und wurde gelöscht"
    local cf="Bitte die E-Mail des Gastes bei Cloudflare aus der Regel „Gäste“ entfernen."
    [ -n "$email" ] && cf="Bitte $email bei Cloudflare aus der Regel „Gäste“ entfernen."
    push "Dateien: Gast $name $([ "$grund" = abgelaufen ] && echo abgelaufen || echo gelöscht)" "Gast $name ($benutzer) $was. $cf"
    ha_post events/dateien_gast_entfernt "$(jq -n --arg b "$benutzer" --arg g "$grund" '{benutzer: $b, grund: $g}')"
}

gaeste_ablauf_pruefen() {
    local jetzt b
    jetzt=$(date +%s)
    for b in $(jq -r --argjson j "$jetzt" '.[] | select(.bis > 0 and .bis <= $j) | .benutzer' "$GAESTE"); do
        gast_entfernen "$b" abgelaufen
    done
}

# Aus der Log-Zeile: erste Anmeldung eines Gastes erkennen (200 = drin, 403 = muss Passwort ändern)
gast_anmeldung_pruefen() {
    local benutzer=$1 eintrag
    benutzer=$(printf '%s' "$benutzer" | tr '[:upper:]' '[:lower:]')
    eintrag=$(jq -c --arg b "$benutzer" 'first(.[] | select(.benutzer == $b and .erste_anmeldung == null)) // empty' "$GAESTE")
    [ -n "$eintrag" ] || return
    (
        flock 9
        jq --arg b "$benutzer" --argjson j "$(date +%s)" 'map(if .benutzer == $b then .erste_anmeldung = $j else . end)' \
            "$GAESTE" > "$GAESTE.neu" && mv "$GAESTE.neu" "$GAESTE"
    ) 9>"$LOCK"
    gaeste_melden
    logbuch "Gast $(jq -r .name <<<"$eintrag") hat sich zum ersten Mal angemeldet"
    push "Dateien: Gast $(jq -r .name <<<"$eintrag") meldet sich an" "$(jq -r .name <<<"$eintrag") hat sich zum ersten Mal im Datei-Manager angemeldet."
    ha_post events/dateien_gast_erste_anmeldung "$(jq -n --arg b "$benutzer" '{benutzer: $b}')"
}

befehl_ausfuehren() {
    local cmd=$1 aktion
    jq -e . >/dev/null 2>&1 <<<"$cmd" || { echo "[dateien] Unbekannte Eingabe ignoriert."; return; }
    aktion=$(jq -r '.aktion // ""' <<<"$cmd")
    case "$aktion" in
        gast_anlegen)  gast_anlegen "$cmd" ;;
        gast_loeschen) gast_entfernen "$(benutzername "$(jq -r '.benutzer // ""' <<<"$cmd")")" geloescht ;;
        ordner)        ordner_melden; gaeste_melden ;;
        melden)        alles_melden ;;
        wochenbericht) wochenbericht_ablegen "$cmd" ;;
        alarm_archiv)  alarm_archiv "$cmd" ;;
        extern)        extern_pruefen ;;
        wiederherstellen) wiederherstellen "$(jq -r '.quelle // "Stick"' <<<"$cmd")" "$(jq -r '.name // ""' <<<"$cmd")" ;;
        *) echo "[dateien] Unbekannte Aktion ignoriert." ;;
    esac
}

# Papierkorb: Eintrag an seinen alten Platz zurück – dieselbe Weiche wie der Menüpunkt im Datei-Manager
wiederherstellen() {
    local quelle=${1:-Stick} name=$2 tok antwort
    case "$name" in ""|*/*|.|..) push "Dateien: nicht wiederhergestellt" "Ungültiger Name."; return ;; esac
    tok=$(admin_token)
    antwort=$(curl -s -m 60 -X POST http://127.0.0.1:8082/dateien-api/wiederherstellen -H "Authorization: Bearer $tok" \
        -H "Content-Type: application/json" -d "$(jq -n --arg q "$quelle" --arg n "$name" '{quelle: $q, namen: [$n]}')")
    if ! jq -e '(.wiederhergestellt // []) | length > 0' >/dev/null 2>&1 <<<"$antwort"; then
        echo "[dateien] Wiederherstellen fehlgeschlagen."
        push "Dateien: nicht wiederhergestellt" "„$name“ konnte nicht zurückgelegt werden: $(jq -r '.fehler[0].grund // .message // "unbekannter Fehler"' <<<"$antwort" 2>/dev/null)"; return
    fi
    # Logbuch-Eintrag kommt aus dem Aktivitätsprotokoll (Verschieben aus dem Papierkorb)
    papierkorb_pruefen
}

# Kjells Benutzer bekommt Zugriff auf alle eingebundenen Sticks (nach jedem Start, falls ein Stick dazukam)
admin_quellen() {
    local tok scopes code
    tok=$(admin_token)
    scopes=$(jq '[.[] | {name, scope: "/", permissions: {view: true, download: true, modify: true, delete: true, create: true, configured: true}}]' "$QUELLEN")
    code=$(fb_api "$tok" PATCH "/api/users?username=$(uri "$USER_NAME")" "$(jq -n --arg u "$USER_NAME" --argjson s "$scopes" \
        '{which: ["scopes"], data: {username: $u, scopes: $s}}')")
    echo "[dateien] Speicher für den Hauptbenutzer gesetzt (HTTP $code)."
}

# Zugriffsregel für einen Gast: „/“ wird gesperrt, jeder freigegebene Ordner erlaubt -> HTTP-Status
regel_setzen() {
    local tok=$1 quelle=$2 pfad=$3 benutzer=$4 erlaubt=true
    [ "$pfad" = / ] && erlaubt=false
    fb_api "$tok" POST "/api/access?source=$(uri "$quelle")&path=$(uri "$pfad")" \
        "$(jq -n --arg b "$benutzer" --argjson a "$erlaubt" '{allow: $a, ruleCategory: "user", value: $b}')"
}

# Alle Zugriffsregeln eines Gastes auf allen Sticks entfernen (beim Löschen und wenn das Anlegen scheitert)
regeln_entfernen() {
    local tok=$1 benutzer=$2 q t
    while IFS= read -r q; do
        for t in deny allow; do
            fb_api "$tok" DELETE "/api/access?source=$(uri "$q")&path=%2F&ruleType=$t&ruleCategory=user&value=$(uri "$benutzer")&cascade=true" >/dev/null
        done
    done < <(jq -r '.[].name' "$QUELLEN")
}

# Wochenbericht als Textdatei auf dem ersten Stick ablegen (Archiv, im Datei-Manager unter „Wochenberichte“)
wochenbericht_ablegen() {
    local kw text datei
    kw=$(jq -r '.kw // ""' <<<"$1" | tr -cd 'A-Za-z0-9-' | head -c 20)
    text=$(jq -r '.text // ""' <<<"$1" | head -c 20000)
    [ -n "$kw" ] && [ -n "$text" ] || return
    mkdir -p "$MNT/Wochenberichte"
    datei="$MNT/Wochenberichte/Wochenbericht-$kw.txt"
    printf '%s\n' "$text" > "$datei" && echo "[dateien] Wochenbericht abgelegt: Wochenberichte/Wochenbericht-$kw.txt"
}

# Alarm-Logbuch eines Monats als Textdatei auf Stick 1 (Ordner „Logbuch“), z. B. {"aktion":"alarm_archiv","monat":"2026-10"}
# Quelle sind nur die bereinigten Einträge (input_text.logbuch_alarm) – Feuerwehr nur als Ereignis, keine Einsatzdaten.
alarm_archiv() {
    local monat start ende datei daten
    monat=$(jq -r '.monat // ""' <<<"$1" | tr -cd '0-9-' | head -c 7)
    [[ "$monat" =~ ^[0-9]{4}-[0-9]{2}$ ]] || return
    start=$(TZ=Europe/Berlin date -d "$monat-01 00:00" -u +%Y-%m-%dT%H:%M:%SZ)
    ende=$(TZ=Europe/Berlin date -d "$monat-01 +1 month" -u +%Y-%m-%dT%H:%M:%SZ)
    daten=$(curl -s -m 60 -H "Authorization: Bearer ${SUPERVISOR_TOKEN:-}" \
        "$HA/logbook/$start?entity=input_text.logbuch_alarm&end_time=$ende")
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$daten" || { echo "[dateien] Alarm-Logbuch $monat nicht abrufbar."; return; }
    mkdir -p "$MNT/Logbuch"
    datei="$MNT/Logbuch/Alarm-Logbuch-$monat.txt"
    {
        echo "Alarm-Logbuch $monat (Home Assistant, ohne Einsatzdaten)"
        echo "================================================"
        jq -r '.[] | select(.message) | "\(.when | sub("\.[0-9]+"; "") | sub("\+00:00$"; "Z") | fromdateiso8601 | strflocaltime("%d.%m.%Y %H:%M"))  \(.message)"' <<<"$daten"
        echo
        echo "Einträge: $(jq '[.[] | select(.message)] | length' <<<"$daten")"
    } > "$datei" && echo "[dateien] Alarm-Logbuch abgelegt: Logbuch/Alarm-Logbuch-$monat.txt"
}

# Ist kjellh.de von außen (über Cloudflare) erreichbar? Für den Feuerwehr-Strecken-Check, kein Webhook-Aufruf.
extern_pruefen() {
    local code
    code=$(curl -s -m 20 -o /dev/null -w '%{http_code}' https://kjellh.de/manifest.json)
    ha_post states/binary_sensor.kjellh_extern_erreichbar "$(jq -n --arg c "$code" --arg z "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{state: (if $c == "200" then "on" else "off" end), attributes: {friendly_name: "kjellh.de von außen erreichbar", device_class: "connectivity", http_status: $c, geprueft: $z}}')"
}

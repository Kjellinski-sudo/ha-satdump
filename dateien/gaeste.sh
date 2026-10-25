# Gästeverwaltung für den Datei-Manager (wird von run.sh eingebunden).
# Befehle kommen als JSON-Zeile über stdin (Home Assistant: hassio.addon_stdin).
# Gast-Passwörter werden nur erzeugt, an Quantum übergeben und per Push an Kjell geschickt –
# nie ins Protokoll, nie in eine Datei.

FBURL=http://127.0.0.1:8080
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

ordner_melden() {
    local liste
    liste=$(find "$MNT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name 'System Volume Information' -printf '%f\n' 2>/dev/null | sort | jq -R . | jq -s .)
    ha_post states/sensor.dateien_ordner "$(jq -n --argjson o "$liste" '{state: ($o|length), attributes: {ordner: $o, friendly_name: "Dateien: Ordner auf dem Stick", icon: "mdi:folder-multiple"}}')"
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

    # Ordner: neuer Gast-Ordner, ganzer Stick oder ein vorhandener Ordner der obersten Ebene
    case "$ordner" in
        __neu__) ordner="Gast-$name"; ordner=$(printf '%s' "$ordner" | tr -d '/\\' | head -c 60); mkdir -p "$MNT/$ordner"; scope="/$ordner" ;;
        ""|/|__alles__) ordner=""; scope="/" ;;
        *) if [[ "$ordner" == */* || "$ordner" == .* || ! -d "$MNT/$ordner" ]]; then
               push "Dateien: Gast nicht angelegt" "Der Ordner „$ordner“ wurde auf dem Stick nicht gefunden."; return
           fi
           scope="/$ordner" ;;
    esac
    case "$recht" in
        hochladen)   perms='{"view":true,"download":true,"modify":false,"delete":false,"create":true,"configured":true}' ;;
        briefkasten) perms='{"view":false,"download":false,"modify":false,"delete":false,"create":true,"configured":true}' ;;
        *) recht=ansehen; perms='{"view":true,"download":true,"modify":false,"delete":false,"create":false,"configured":true}' ;;
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
    code=$(fb_api "$tok" PATCH "/api/users?username=$(uri "$benutzer")" "$(jq -n --arg u "$benutzer" --arg s "$scope" \
        --argjson perm "$perms" --argjson rp "$rp" --argjson lp "$lp" '{which: ["scopes","requirePasswordChange","lockPassword"],
        data: {username: $u, requirePasswordChange: $rp, lockPassword: $lp, scopes: [{name: "Stick", scope: $s, permissions: $perm}]}}')")
    if [ "$code" != 204 ] && [ "$code" != 200 ]; then
        fb_api "$tok" DELETE "/api/users?username=$(uri "$benutzer")" >/dev/null
        echo "[dateien] Gast-Rechte setzen fehlgeschlagen (HTTP $code), Gast wieder entfernt."
        push "Dateien: Gast nicht angelegt" "Die Rechte konnten nicht gesetzt werden (Fehler $code). Der Gast wurde wieder entfernt."; return
    fi

    jetzt=$(date +%s)
    if [ "$tage" -gt 0 ]; then bis=$((jetzt + tage * 86400)); else bis=0; fi
    (
        flock 9
        jq --arg n "$name" --arg b "$benutzer" --arg r "$recht" --arg o "${ordner:-Ganzer Stick}" --arg e "$email" \
           --argjson bis "$bis" --argjson j "$jetzt" \
           '. + [{name: $n, benutzer: $b, recht: $r, ordner: $o, email: $e, bis: $bis, angelegt: $j, erste_anmeldung: null}]' \
           "$GAESTE" > "$GAESTE.neu" && mv "$GAESTE.neu" "$GAESTE"
    ) 9>"$LOCK"
    gaeste_melden
    ordner_melden
    echo "[dateien] Gast „$benutzer“ angelegt ($recht, ${ordner:-ganzer Stick}, $tage Tage)."
    logbuch "Gast $name ($benutzer) angelegt: $recht, Ordner ${ordner:-ganzer Stick}, $([ "$tage" -gt 0 ] && echo "$tage Tage" || echo unbegrenzt)"

    case "$recht" in
        ansehen) hinweis="nur ansehen und herunterladen" ;;
        hochladen) hinweis="ansehen, herunterladen und hochladen" ;;
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
Ordner: ${ordner:-ganzer Stick} · $hinweis
Gültig: $gueltig
$LINK
$cf" ;;
        dauerhaft) push "Dateien: Gast $name angelegt" "Benutzer: $benutzer
Passwort: $pw
Ordner: ${ordner:-ganzer Stick} · $hinweis
Gültig: $gueltig
$LINK
$cf" ;;
        selbst)    push "Dateien: Gast $name angelegt" "Benutzer: $benutzer
Passwort bitte selbst setzen: im Datei-Manager Einstellungen > Benutzerverwaltung > $benutzer.
Ordner: ${ordner:-ganzer Stick} · $hinweis
Gültig: $gueltig
$cf" ;;
    esac
    pw=""
    ha_post events/dateien_gast_angelegt "$(jq -n --arg b "$benutzer" --arg r "$recht" --arg o "${ordner:-Ganzer Stick}" '{benutzer: $b, recht: $r, ordner: $o}')"
}

# gast_entfernen BENUTZER GRUND(geloescht|abgelaufen)
gast_entfernen() {
    local benutzer=$1 grund=$2 tok code eintrag email name
    eintrag=$(jq -c --arg b "$benutzer" 'first(.[] | select(.benutzer == $b)) // empty' "$GAESTE")
    [ -n "$eintrag" ] || { echo "[dateien] Gast „$benutzer“ unbekannt."; return; }
    name=$(jq -r .name <<<"$eintrag"); email=$(jq -r .email <<<"$eintrag")
    tok=$(admin_token)
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
        *) echo "[dateien] Unbekannte Aktion ignoriert." ;;
    esac
}

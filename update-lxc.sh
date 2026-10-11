#!/bin/bash

# ======================================================================
# SCRIPT: update-lxc.sh
# VERSIONE: 2.1.0 (LXC con stack critici sempre per ultimi + wireguard)
# ======================================================================

# Rileva le dimensioni del terminale
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
TERM_HEIGHT=$(tput lines 2>/dev/null || echo 24)

# Calcola una larghezza sicura (80% dello schermo, max 70, min 40)
IFACE_WIDTH=$(( TERM_WIDTH * 80 / 100 ))
if [ $IFACE_WIDTH -gt 70 ]; then IFACE_WIDTH=70; fi
if [ $IFACE_WIDTH -lt 40 ]; then IFACE_WIDTH=40; fi

# Calcola un'altezza safe (80% dello schermo)
IFACE_HEIGHT=$(( TERM_HEIGHT * 80 / 100 ))
if [ $IFACE_HEIGHT -lt 15 ]; then IFACE_HEIGHT=15; fi

# Altezza della lista interna (altezza finestra - 10 righe di bordi/testo)
LIST_HEIGHT=$(( IFACE_HEIGHT - 10 ))

echo $$ > /var/run/update-lxc.pid
trap "echo -ne '\033[0m'; rm -f /var/run/update-lxc.pid" EXIT

# --- USER CONFIG ---
SCAN_ROOTS="/root /opt/stacks"
DOCKGE_PATHS="/root/dockge_install/dockge /opt/dockge"
KEEP_LAST_SNAPSHOT=true
LOG_FILE="/root/script.tmp"
SCRIPT_FISICO="/tmp/script.sh"
CRITICAL_STACKS="tailscale termix wireguard nginx proxy npmplus"   # nomi (anche parziali) degli stack da aggiornare per ultimi
CRITICAL_WAIT_TRIES=9                # tentativi di verifica ripartenza (10s ciascuno)
# -------------------

# --- CONFIGURAZIONE VARIABILI INTERNE ---
SCRIPT_VERSION="2.1.0"
SNAP_PREFIX="AUTO_UPDATE_SNAP"
HOST_IP=$(hostname -I | awk '{print $1}')

# Se SCRIPT_FISICO non esiste, usa il percorso di questo script
if [ ! -f "$SCRIPT_FISICO" ]; then
    SCRIPT_FISICO="$(readlink -f "$0")"
fi

C_DEFAULT='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'

declare -a UPDATE_LOGS
DRY_RUN=false
CLEAN_MODE=false
SKIP_SNAPSHOT=false
HA_MODE=false
ARGS=()

# --- FUNZIONE HELP ---
show_help() {
    echo -e "${C_CYAN}Utilizzo:${C_DEFAULT} $0 <ID_LXC|all> [opzioni]"
    echo ""
    echo -e "${C_YELLOW}Opzioni CLI:${C_DEFAULT}"
    echo "  -i <ID>        ID del container (usato dalla GUI)"
    echo "  --dry-run      Simulazione senza modifiche"
    echo "  --no-snap      Salta la creazione degli snapshot"
    echo "  clean          Esegui pulizia snapshot"
    echo "  ha             Notifiche Home Assistant"
    echo ""
    echo "Info: Avvia senza argomenti per l'interfaccia grafica."
    exit 0
}

# --- LOGICA INTERATTIVA (Solo se mancano argomenti) ---
if [ $# -eq 0 ]; then
    if ! command -v whiptail &> /dev/null; then
        echo -e "${C_RED}Errore: whiptail non trovato.${C_DEFAULT}"
        exit 1
    fi

    LXC_RAW=$(pct list | awk 'NR>1 {print $1 " [" $3 "] off"}')
    LXC_MENU="BACKGROUND [Esegui_in_background] off ALL [Tutti] off $LXC_RAW"

    CHOICES=$(whiptail --title "Proxmox LXC Updater v$SCRIPT_VERSION" \
        --checklist "Seleziona i container (Spazio per selezionare):" \
        $IFACE_HEIGHT $IFACE_WIDTH $LIST_HEIGHT \
        $LXC_MENU 3>&1 1>&2 2>&3)

    exit_status=$?
    if [ $exit_status -ne 0 ]; then
        echo -e "\n${C_YELLOW}Operazione annullata.${C_DEFAULT}"
        exit 0
    fi

    [ -z "$CHOICES" ] && exit 0
    CHOICES=$(echo "$CHOICES" | tr -d '"')

    # Rilevamento flag BACKGROUND
    IS_PERSISTENT=false
    if [[ " $CHOICES " == *" BACKGROUND "* ]]; then
        IS_PERSISTENT=true
        CHOICES=$(echo "$CHOICES" | sed 's/BACKGROUND//g')
    fi

    if [[ " $CHOICES " == *" ALL "* ]]; then
        CHOICES="all"
    fi

    OPTIONS=$(whiptail --title "Opzioni di Aggiornamento" \
        --checklist "Seleziona le flag desiderate:" \
        $IFACE_HEIGHT $IFACE_WIDTH 5 \
        "clean" "Esegui pulizia snapshot [-c]" OFF \
        "nosnap" "Salta snapshot [-s]" OFF \
        "dryrun" "Simulazione (Dry Run) [-n]" OFF \
        "ha" "Modalità Home Assistant [-ha]" OFF 3>&1 1>&2 2>&3)

    if [ $? -ne 0 ]; then
        echo -e "\n${C_YELLOW}Operazione annullata.${C_DEFAULT}"
        exit 0
    fi

    FINAL_OPTS=""
    [[ "$OPTIONS" == *"clean"* ]] && FINAL_OPTS="$FINAL_OPTS clean"
    [[ "$OPTIONS" == *"nosnap"* ]] && FINAL_OPTS="$FINAL_OPTS --no-snap"
    [[ "$OPTIONS" == *"dryrun"* ]] && FINAL_OPTS="$FINAL_OPTS --dry-run"
    [[ "$OPTIONS" == *"ha"* ]] && FINAL_OPTS="$FINAL_OPTS ha"

    # Costruisce gli argomenti ID: una SOLA esecuzione con tutti i container,
    # così l'ordinamento (critici per ultimi) vale su tutta la lista
    if [[ " $CHOICES " == *"all"* ]]; then
        IDS_ARGS="all"
    else
        IDS_ARGS=""
        for VMID in $CHOICES; do IDS_ARGS="$IDS_ARGS -i $VMID"; done
    fi

    # --- GESTIONE BACKGROUND ASINCRONO ---
    if [ "$IS_PERSISTENT" = true ]; then
        > "$LOG_FILE"
        echo -e "🚀 Aggiornamento Docker LXC avviato in background alle $(date)\n" >> "$LOG_FILE"

        # Sessione completamente scollegata dal terminale (anti-SIGHUP / anti-drop Tailscale)
        setsid bash -c '
            LOG="$1"; SCRIPT="$2"; shift 2
            bash "$SCRIPT" "$@" >> "$LOG" 2>&1
            echo -e "\n🏁 Tutti i task completati alle $(date)" >> "$LOG"
        ' _ "$LOG_FILE" "$SCRIPT_FISICO" $IDS_ARGS $FINAL_OPTS </dev/null >/dev/null 2>&1 &
        disown

        echo -e "${C_GREEN}🚀 Processo inviato in background con successo!${C_DEFAULT}"
        echo -e "⚠️  L'aggiornamento CONTINUERÀ anche in caso di disconnessione Tailscale o SSH."
        echo -e "--------------------------------------------------------"
        echo -e "📋 Apertura log... (Ctrl+C per uscire dal log senza fermare l'esecuzione)\n"
        sleep 1
        tail -f "$LOG_FILE"
        exit 0
    fi

    # Esecuzione standard in primo piano (unica esecuzione, ordine gestito dallo script)
    bash "$SCRIPT_FISICO" $IDS_ARGS $FINAL_OPTS
    exit 0
fi

# --- GESTIONE ARGOMENTI (CLI) ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i)                 ARGS+=("$2"); shift 2 ;;
        --dry-run)          DRY_RUN=true; shift ;;
        --no-snap)          SKIP_SNAPSHOT=true; shift ;;
        clean|--clean)      CLEAN_MODE=true; shift ;;
        ha|--ha)            HA_MODE=true; shift ;;
        -h|--help)          show_help ;;
        *)                  ARGS+=("$1"); shift ;;
    esac
done

# Setup Home Assistant
if [ "$HA_MODE" = true ]; then
    [ -f "/root/ha_secret.conf" ] && source /root/ha_secret.conf
    C_RED="" ; C_GREEN="" ; C_YELLOW="" ; C_CYAN="" ; C_DEFAULT=""
fi

log_msg() { [ "$HA_MODE" = false ] && echo -e "${1}${C_DEFAULT}"; }
log_status() { echo -e "$1" >&2; }

if [ ${#ARGS[@]} -eq 0 ]; then show_help; fi

# --- MESSAGGI DI INTESTAZIONE ---
log_msg "${C_CYAN}Aggiornamento LXC Docker (v$SCRIPT_VERSION) - Host: $HOST_IP${C_DEFAULT}"
[ "$DRY_RUN" = true ] && log_msg "${C_YELLOW}*** MODALITÀ DRY-RUN ATTIVA ***${C_DEFAULT}"
[ "$SKIP_SNAPSHOT" = true ] && log_msg "${C_YELLOW}*** SNAPSHOT DISABILITATI ***${C_DEFAULT}"

# ======================================================================
# FUNZIONI CORE
# ======================================================================

esegui_remoto() {
    local ID=$1
    local CMD=$2
    pct exec "$ID" -- bash -c "export LC_ALL=C.UTF-8 && $CMD" 2>/dev/null
}

# Ritorna 0 se lo stack è tra quelli critici (Tailscale/Termix)
is_critical() {
    local NAME="${1,,}"
    local C
    for C in $CRITICAL_STACKS; do
        [[ "$NAME" == *"$C"* ]] && return 0
    done
    return 1
}

# Elenca le cartelle degli stack compose dentro un LXC
trova_stacks_remoto() {
    local ID=$1
    esegui_remoto "$ID" "find $SCAN_ROOTS -mindepth 1 -maxdepth 2 -type f -regex \".*\(docker-compose\|compose\).y\(a\)?ml\" -print0 2>/dev/null | xargs -0 -I {} dirname {} | sort -u"
}

# Ritorna 0 se l'LXC (acceso) contiene almeno uno stack critico
lxc_ha_critici() {
    local ID=$1
    [ "$(pct status $ID 2>/dev/null)" = "status: running" ] || return 1
    local P
    for P in $(trova_stacks_remoto "$ID"); do
        is_critical "$(basename "$P")" && return 0
    done
    return 1
}

trova_lxc_ids() {
    local SEARCH_TERMS=("$@")
    local ACTIVE_IDS=$(pct list | awk 'NR>1 {print $1}' || true)
    local FILTERED_IDS=()
    for TERM in "${SEARCH_TERMS[@]}"; do
        if [ "$TERM" == "all" ]; then FILTERED_IDS+=($ACTIVE_IDS); break; fi
        for ID in $ACTIVE_IDS; do
            if [ "$ID" == "$TERM" ]; then FILTERED_IDS+=("$ID"); continue; fi
            local HOSTNAME=$(pct config "$ID" 2>/dev/null | grep 'hostname' | awk '{print $2}' || true)
            if echo "$HOSTNAME" | grep -qi "$TERM"; then FILTERED_IDS+=("$ID"); fi
        done
    done
    echo "${FILTERED_IDS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

crea_snapshot() {
    local ID=$1
    local NAME="${SNAP_PREFIX}_$(date +%Y%m%d%H%M%S)_${ID}"
    log_status "${C_CYAN}Creazione snapshot $NAME...${C_DEFAULT}"
    if [ "$DRY_RUN" = true ]; then echo "$NAME"; return 0; fi
    if pct snapshot $ID "$NAME" &>/dev/null; then echo "$NAME"; return 0;
    else log_status "${C_RED}ERRORE snapshot.${C_DEFAULT}"; return 1; fi
}

esegui_rollback() {
    local ID=$1
    local RAW_SNAP=$2
    local CLEAN_SNAP=$(echo "$RAW_SNAP" | grep -o "${SNAP_PREFIX}_[0-9]*_${ID}" | tail -n 1)
    [ -z "$CLEAN_SNAP" ] && return 1
    log_status "${C_RED}#### ROLLBACK LXC $ID A $CLEAN_SNAP ####${C_DEFAULT}"
    pct rollback $ID "$CLEAN_SNAP" && pct start $ID && pct delsnapshot $ID "$CLEAN_SNAP"
}

aggiorna_stack() {
    local ID=$1; local PATH_STACK=$2; local NOME_STACK=$3
    local CHECK=$(esegui_remoto "$ID" "[ -d \"$PATH_STACK\" ] && echo 'ok'")
    [ "$CHECK" != "ok" ] && return 0
    log_status "      Check $NOME_STACK..."

    local RUNNING_BEFORE=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose ps --format '{{.Service}}' --filter \"status=running\" 2>/dev/null" | xargs)
    # PRE calcolato con lo stesso metodo di POST (immagini configurate nel compose), così il confronto vede solo ciò che cambia con il pull
    local PRE_IDS=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose config --images 2>/dev/null | xargs -r docker inspect --format='{{.Id}}' 2>/dev/null | sed 's/sha256://g' | sort -u | xargs")

    if ! esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose pull -q"; then
        log_status "${C_RED}      ✖ Errore Pull su $NOME_STACK${C_DEFAULT}"; return 1
    fi

    local POST_IDS=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose config --images 2>/dev/null | xargs -r docker inspect --format='{{.Id}}' 2>/dev/null | sed 's/sha256://g' | sort -u | xargs")

    if [ -n "$POST_IDS" ] && [ "$PRE_IDS" != "$POST_IDS" ]; then
        log_status "${C_GREEN}      ✔ Aggiornamento trovato per $NOME_STACK!${C_DEFAULT}"
        if [ "$DRY_RUN" = true ]; then UPDATE_LOGS+=("✅ LXC $ID - $NOME_STACK: Disponibile (Dry Run)"); return 0; fi

        local UP_OUT UP_RC IDS_BEFORE IDS_AFTER
        # ID dei container prima di up -d: se cambiano, il container è stato davvero ricreato
        IDS_BEFORE=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose ps -a -q | sort | xargs")

        if is_critical "$NOME_STACK"; then
            log_status "${C_YELLOW}      ⚠ Stack critico: avvio staccato dalla sessione${C_DEFAULT}"

            # Lo script staccato gira sull'HOST (non dentro l'LXC): sopravvive al drop della VPN
            # e il log resta leggibile sull'host
            local HLOG="/root/critical_up_${ID}_${NOME_STACK}.log"
            local HSCRIPT
            HSCRIPT=$(mktemp /tmp/critical_up.XXXXXX)
            cat > "$HSCRIPT" <<EOF
#!/bin/bash
pct exec $ID -- bash -c 'export LC_ALL=C.UTF-8; cd "$PATH_STACK" && docker compose up -d 2>&1; sleep 5; docker compose up -d 2>&1'
echo __DONE__
EOF
            : > "$HLOG"
            setsid nohup bash "$HSCRIPT" >"$HLOG" 2>&1 </dev/null &

            # Quanti servizi dovevano essere attivi (minimo 1)
            local EXPECTED=$(echo "$RUNNING_BEFORE" | wc -w)
            [ "${EXPECTED:-0}" -lt 1 ] && EXPECTED=1

            # 1) Attende la fine di up -d (marker nel log)
            local TRY
            for TRY in $(seq 1 "$CRITICAL_WAIT_TRIES"); do
                sleep 10
                grep -q "__DONE__" "$HLOG" 2>/dev/null && break
            done

            # 2) Verifica che i servizi siano ripartiti
            local CHK=0
            UP_RC=1
            for TRY in 1 2 3 4 5 6; do
                CHK=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose ps --status running -q | wc -l")
                if [ "${CHK:-0}" -ge "$EXPECTED" ]; then UP_RC=0; break; fi
                sleep 10
            done

            UP_OUT=$(cat "$HLOG" 2>/dev/null)
            rm -f "$HSCRIPT"

            if [ $UP_RC -ne 0 ]; then
                log_status "${C_RED}      ✖ $NOME_STACK non ripartito (log: $HLOG)${C_DEFAULT}"
            fi
        else
            UP_OUT=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose up -d 2>&1")
            UP_RC=$?
        fi

        IDS_AFTER=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose ps -a -q | sort | xargs")

        if [ $UP_RC -eq 0 ]; then
            # Ferma i servizi che erano spenti prima dell'aggiornamento
            local ALL_SERVICES=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose config --services 2>/dev/null")
            for SERVICE in $ALL_SERVICES; do
                if [[ ! " $RUNNING_BEFORE " =~ " $SERVICE " ]]; then
                    esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose stop $SERVICE" >/dev/null 2>&1
                fi
            done
            local UPDATED_NAMES=$(echo "$UP_OUT" | grep -E 'Recreated|Started|Created' | sed -E 's/.*Container //;s/ .*//' | sort -u | paste -sd ", " -)
            # Se gli ID dei container sono cambiati, è stato ricreato anche se il testo non lo dice
            if [ -z "$UPDATED_NAMES" ] && [ -n "$IDS_AFTER" ] && [ "$IDS_AFTER" != "$IDS_BEFORE" ]; then
                UPDATED_NAMES="container ricreati"
            fi
            if [ -n "$UPDATED_NAMES" ]; then
                UPDATE_LOGS+=("✅ LXC $ID - $NOME_STACK: $UPDATED_NAMES")
            else
                # up -d non ha ricreato nulla: falso positivo del confronto immagini
                UPDATE_LOGS+=("🟡 LXC $ID - $NOME_STACK: Nessuna modifica (nessun container ricreato).")
            fi
            return 0
        else
            return 1
        fi
    else
        UPDATE_LOGS+=("🟡 LXC $ID - $NOME_STACK: Nessuna modifica.")
        return 0
    fi
}

processa_lxc() {
    local ID=$1
    if ! pct status $ID &>/dev/null; then return 1; fi
    local NOME=$(pct config $ID | grep 'hostname' | awk '{print $2}' || echo "LXC $ID")
    log_msg "--------------------------------------------------------"
    log_msg "${C_CYAN}#### PROCESSO LXC $ID ($NOME) ####${C_DEFAULT}"

    [ "$(pct status $ID)" != "status: running" ] && { log_status "LXC non in esecuzione."; return 0; }

    local SNAP_NAME=""
    if [ "$SKIP_SNAPSHOT" = false ]; then
        SNAP_NAME=$(crea_snapshot $ID)
        [ $? -ne 0 ] && return 1
    fi

    local FAILED=false
    local CRIT_FAILED=false

    # 1) Dockge (se non è uno stack critico)
    for D_PATH in $DOCKGE_PATHS; do
        if ! aggiorna_stack "$ID" "$D_PATH" "Dockge"; then FAILED=true; break; fi
    done

    # 2) Altri stack: prima i normali, poi i critici per ultimi
    if [ "$FAILED" = false ]; then
        local STACKS=$(trova_stacks_remoto "$ID")

        local NORMAL="" CRIT="" P
        for P in $STACKS; do
            local SKIP_S=false
            for D in $DOCKGE_PATHS; do [[ "$P" == "$D"* ]] && SKIP_S=true; done
            [ "$SKIP_S" = true ] && continue
            if is_critical "$(basename "$P")"; then CRIT+="$P "; else NORMAL+="$P "; fi
        done

        # Stack normali: un errore innesca il rollback
        for P in $NORMAL; do
            if ! aggiorna_stack "$ID" "$P" "$(basename "$P")"; then FAILED=true; break; fi
        done

        # Stack critici: nessun rollback (la connessione può cadere senza che sia un vero errore)
        if [ "$FAILED" = false ]; then
            for P in $CRIT; do
                if ! aggiorna_stack "$ID" "$P" "$(basename "$P")"; then
                    CRIT_FAILED=true
                    UPDATE_LOGS+=("⚠️ LXC $ID - $(basename "$P"): non ripartito, controlla manualmente")
                fi
            done
        fi
    fi

    # Gestione esito
    if [ "$FAILED" = true ]; then
        [ -n "$SNAP_NAME" ] && esegui_rollback "$ID" "$SNAP_NAME"
        UPDATE_LOGS+=("❌ LXC $ID - Errore durante l'aggiornamento")
        return 1
    fi

    # Se un critico è fallito mantengo lo snapshot per un eventuale rollback manuale
    if [ "$CRIT_FAILED" = true ]; then
        log_status "${C_YELLOW}      Snapshot mantenuto per rollback manuale: $SNAP_NAME${C_DEFAULT}"
        return 1
    fi

    # Pulizia snapshot post-aggiornamento riuscito
    if [ "$DRY_RUN" = false ]; then
        if [ "$CLEAN_MODE" = true ]; then
            log_status "${C_YELLOW}      Pulizia totale snapshot temporanei...${C_DEFAULT}"
            local ALL_AUTO_SNAPS=$(pct listsnapshot $ID | awk '{print $2}' | grep "^$SNAP_PREFIX" || true)
            for S in $ALL_AUTO_SNAPS; do pct delsnapshot $ID $S &>/dev/null; done
        elif [ "$KEEP_LAST_SNAPSHOT" = true ] && [ -n "$SNAP_NAME" ]; then
            local OLD_SNAPS=$(pct listsnapshot $ID | awk '{print $2}' | grep "^$SNAP_PREFIX" | grep -v "$SNAP_NAME" || true)
            for OS in $OLD_SNAPS; do pct delsnapshot $ID $OS &>/dev/null; done
        fi

        # Pulizia immagini Docker orfane
        esegui_remoto "$ID" "docker image prune -af" >/dev/null
    fi

    return 0
}

# --- ESECUZIONE ---
LXC_IDS=$(trova_lxc_ids "${ARGS[@]}")
[ -z "$LXC_IDS" ] && { echo "Nessun LXC trovato."; exit 1; }

# Ordina: prima gli LXC senza stack critici, per ultimi quelli con Tailscale/Termix/WireGuard
LXC_NORMAL=""
LXC_CRIT=""
for ID in $LXC_IDS; do
    if lxc_ha_critici "$ID"; then LXC_CRIT+="$ID "; else LXC_NORMAL+="$ID "; fi
done
[ -n "$LXC_CRIT" ] && log_msg "${C_YELLOW}LXC con stack critici (processati per ultimi): $LXC_CRIT${C_DEFAULT}"

for ID in $LXC_NORMAL $LXC_CRIT; do
    processa_lxc "$ID"
done

# --- REPORT FINALE E NOTIFICA ---
REPORT_TEXT=""
UPDATED_COUNT=0
for ENTRY in "${UPDATE_LOGS[@]}"; do
    if [[ "$ENTRY" == "✅"* ]]; then
        REPORT_TEXT+="${ENTRY}\n"
        ((UPDATED_COUNT++))
    elif [[ "$ENTRY" == "⚠️"* || "$ENTRY" == "❌"* ]]; then
        REPORT_TEXT+="${ENTRY}\n"
    fi
done

if [ "$HA_MODE" = true ]; then
    MSG_BODY=$(echo -e "${REPORT_TEXT:-Nessun aggiornamento rilevato.}")
    JSON_PAYLOAD=$(echo "$MSG_BODY" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g')
    curl -k -s -X POST -H "Authorization: $HA_TOKEN" -H "Content-Type: application/json" \
         -d "{\"title\": \"LXC Update Report\", \"message\": \"$JSON_PAYLOAD\"}" \
         "$HA_URL" > /dev/null
    echo "DONE: Processo completato. $UPDATED_COUNT stack aggiornati."
else
    echo -e "\n--- REPORT FINALE ---"
    for E in "${UPDATE_LOGS[@]}"; do
        if [[ "$E" == "✅"* ]]; then echo -e "${C_GREEN}$E${C_DEFAULT}"
        elif [[ "$E" == "🟡"* ]]; then echo -e "${C_YELLOW}$E${C_DEFAULT}"
        else echo -e "${C_RED}$E${C_DEFAULT}"; fi
    done
fi

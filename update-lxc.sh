#!/bin/bash

# ======================================================================
# SCRIPT: update-lxc.sh
# VERSIONE: 1.9.3 (Fix Background Asincrono Anti-Disconnessione VPN)
# ======================================================================

# Rileva le dimensions del terminale
TERM_WIDTH=$(tput cols)
TERM_HEIGHT=$(tput lines)

# Calcola una larghezza sicura (80% dello schermo, max 70, min 40)
IFACE_WIDTH=$(( TERM_WIDTH * 80 / 100 ))
if [ $IFACE_WIDTH -gt 70 ]; then IFACE_WIDTH=70; fi
if [ $IFACE_WIDTH -lt 40 ]; then IFACE_WIDTH=40; fi

# Calcola un'altezza safe (80% dello schermo)
IFACE_HEIGHT=$(( TERM_HEIGHT * 80 / 100 ))
if [ $IFACE_HEIGHT -lt 15 ]; then IFACE_HEIGHT=15; fi

# Calcola l'altezza della lista interna (altezza finestra - 10 righe di bordi/testo)
LIST_HEIGHT=$(( IFACE_HEIGHT - 10 ))

echo $$ > /var/run/update-lxc.pid
trap "echo -ne '\033[0m'; rm -f /var/run/update-lxc.pid" EXIT

# --- USER CONFIG ---
SCAN_ROOTS="/root /opt/stacks"
DOCKGE_PATHS="/root/dockge_install/dockge /opt/dockge" 
KEEP_LAST_SNAPSHOT=true 
LOG_FILE="/root/script.tmp"
SCRIPT_FISICO="/tmp/script.sh"
# -------------------

# --- CONFIGURAZIONE VARIABILI INTERNE ---
SCRIPT_VERSION="1.9.3"
SNAP_PREFIX="AUTO_UPDATE_SNAP"
HOST_IP=$(hostname -I | awk '{print $1}')

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

    # --- STRATEGIA DI BACKUP / GESTIONE BACKGROUND ASINCRONO ---
    if [ "$Keep_Last_Snapshot" = true ] && [ "$IS_PERSISTENT" = true ]; then
        > "$LOG_FILE"
        echo -e "🚀 Aggiornamento Docker LXC avviato in background totale alle $(date)\n" >> "$LOG_FILE"
        
        # Risolviamo la lista dei container nel caso sia stato selezionato "all"
        LXC_LIST=$([[ " $CHOICES " == *"all"* ]] && pct list | grep running | awk '{print $1}' || echo $CHOICES)
        
        # INTERO CICLO IN SUB-SHELL DEMONIZZATO (&) E PROTETTO (nohup)
        (
            for VMID in $LXC_LIST; do
                VMID_CLEAN=$(echo "$VMID" | xargs)
                [[ -z "$VMID_CLEAN" ]] && continue
                echo -e "📦 Avvio task per LXC $VMID_CLEAN..." >> "$LOG_FILE"
                
                # Il nohup interno garantisce l'immunità totale ai SIGHUP di rete
                nohup bash "$SCRIPT_FISICO" -i "$VMID_CLEAN" $FINAL_OPTS >> "$LOG_FILE" 2>&1
            done
        ) &
        
        echo -e "${C_GREEN}🚀 Processo inviato in background con successo!${C_DEFAULT}"
        echo -e "⚠️  L'aggiornamento CONTINUERÀ anche in caso di disconnessione Tailscale o SSH."
        echo -e "--------------------------------------------------------"
        echo -e "📋 Apertura log in corso... (Premi Ctrl+C per uscire senza fermare l'esecuzione)\n"
        sleep 1
        tail -f "$LOG_FILE"
        exit 0
    fi

    # Esecuzione standard in primo piano (se BACKGROUND non è selezionato)
    for VMID in $CHOICES; do
        VMID_CLEAN=$(echo "$VMID" | xargs)
        [[ -z "$VMID_CLEAN" ]] && continue
        echo -e "\n${C_CYAN}>>> AVVIO LXC: $VMID_CLEAN${C_DEFAULT}"
        bash "$0" -i "$VMID_CLEAN" $FINAL_OPTS 2>/dev/null || bash "$SCRIPT_FISICO" -i "$VMID_CLEAN" $FINAL_OPTS
    done
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
    C_INFO="" ; C_ERROR="" ; C_SUCCESS="" ; C_WARNING="" ; C_CYAN="" ; C_DEFAULT=""
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
    local PRE_IDS=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose ps -a -q | xargs -r docker inspect --format='{{.Image}}' 2>/dev/null | sed 's/sha256://g' | sort -u | xargs")

    if ! esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose pull -q"; then
        log_status "${C_RED}      ✖ Errore Pull su $NOME_STACK${C_DEFAULT}"; return 1 
    fi
    
    local POST_IDS=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose config --images 2>/dev/null | xargs -r docker inspect --format='{{.Id}}' 2>/dev/null | sed 's/sha256://g' | sort -u | xargs")

    if [ -n "$POST_IDS" ] && [ "$PRE_IDS" != "$POST_IDS" ]; then
        log_status "${C_GREEN}      ✔ Aggiornamento trovato per $NOME_STACK!${C_DEFAULT}"
        if [ "$DRY_RUN" = true ]; then UPDATE_LOGS+=("✅ LXC $ID - $NOME_STACK: Disponibile (Dry Run)"); return 0; fi

        local UP_OUT=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose up -d 2>&1")
        if [ $? -eq 0 ]; then
            local ALL_SERVICES=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose config --services 2>/dev/null")
            for SERVICE in $ALL_SERVICES; do
                if [[ ! " $RUNNING_BEFORE " =~ " $SERVICE " ]]; then
                    esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose stop $SERVICE" >/dev/null 2>&1
                fi
            done
            local UPDATED_NAMES=$(echo "$UP_OUT" | grep -E 'Recreated|Started|Created' | sed -E 's/.*Container //;s/ .*//' | sort -u | paste -sd ", " -)
            UPDATE_LOGS+=("✅ LXC $ID - $NOME_STACK: ${UPDATED_NAMES:-Aggiornato}")
            return 0
        else return 1; fi
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
    for D_PATH in $DOCKGE_PATHS; do
        if ! aggiorna_stack "$ID" "$D_PATH" "Dockge"; then FAILED=true; break; fi
    done
    
    # Aggiorna altri Stack
    if [ "$FAILED" = false ]; then
        local STACKS=$(esegui_remoto "$ID" "find $SCAN_ROOTS -mindepth 1 -maxdepth 2 -type f -regex \".*\(docker-compose\|compose\).y\(a\)?ml\" -print0 2>/dev/null | xargs -0 -I {} dirname {} | sort -u")
        for P in $STACKS; do
            local SKIP_S=false
            for D in $DOCKGE_PATHS; do [[ "$P" == "$D"* ]] && SKIP_S=true; done
            [ "$SKIP_S" = true ] && continue
            if ! aggiorna_stack "$ID" "$P" "$(basename "$P")"; then FAILED=true; break; fi
        done
    fi

    # Gestione Esito
    if [ "$FAILED" = true ]; then
        [ -n "$SNAP_NAME" ] && esegui_rollback "$ID" "$SNAP_NAME"
        UPDATE_LOGS+=("❌ LXC $ID - Errore durante l'aggiornamento")
        return 1
    fi
    
    # Pulizia Snapshot post-aggiornamento riuscito
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

for ID in $LXC_IDS; do 
    processa_lxc "$ID"
done

# --- REPORT FINALE E NOTIFICA ---
REPORT_TEXT=""
UPDATED_COUNT=0
for ENTRY in "${UPDATE_LOGS[@]}"; do
    if [[ "$ENTRY" == "✅"* ]]; then
        REPORT_TEXT+="${ENTRY}\n"
        ((UPDATED_COUNT++))
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

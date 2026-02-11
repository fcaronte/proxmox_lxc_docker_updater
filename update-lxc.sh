#!/bin/bash

# ======================================================================
# SCRIPT: update-lxc.sh
# VERSIONE: 1.8.9 (Restore Header Info + Tag Resolution)
# ======================================================================

# Crea un file di "lavoro in corso"
echo $$ > /var/run/update-lxc.pid
# Reset colori e rimozione PID all'uscita
trap "echo -ne '\033[0m'; rm -f /var/run/update-lxc.pid" EXIT

# --- USER CONFIG ---
SCAN_ROOTS="/root /opt/stacks"
DOCKGE_PATHS="/root/dockge_install/dockge /opt/dockge" 
KEEP_LAST_SNAPSHOT=true 
# -------------------

# --- CONFIGURAZIONE VARIABILI INTERNE ---
SCRIPT_VERSION="1.8.9"
SNAP_PREFIX="AUTO_UPDATE_SNAP"
HOST_IP=$(hostname -I | awk '{print $1}')

C_DEFAULT='\033[0m'
C_RED='\033[0;31m'    
C_GREEN='\033[0;32m'  
C_YELLOW='\033[1;33m' 
C_CYAN='\033[0;36m'   

declare -a UPDATE_LOGS

# --- GESTIONE ARGOMENTI ---
DRY_RUN=false
CLEAN_MODE=false
SKIP_SNAPSHOT=false
HA_MODE=false
ARGS=()

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --no-snap) SKIP_SNAPSHOT=true ;;
        ha)        HA_MODE=true ;;
        clean)     CLEAN_MODE=true ;;
        *)         [ "$arg" != "--" ] && ARGS+=("$arg") ;;
    esac
done

# Caricamento segreti e setup modalità HA
if [ "$HA_MODE" = true ]; then
    [ -f "/root/ha_secret.conf" ] && source /root/ha_secret.conf
    C_INFO="" ; C_ERROR="" ; C_SUCCESS="" ; C_WARNING="" ; C_CYAN="" ; C_DEFAULT=""
fi

log_msg() {
    if [ "$HA_MODE" = false ]; then echo -e "${1}${C_DEFAULT}"; fi
}

log_status() {
    echo -e "$1" >&2
}

if [ ${#ARGS[@]} -eq 0 ]; then
    echo "Utilizzo: $0 <ID_LXC|all> [ha] [--no-snap] [--dry-run]"
    exit 1
fi

# --- MESSAGGI DI INTESTAZIONE (Ripristinati) ---
log_msg "${C_CYAN}Aggiornamento LXC Docker (v$SCRIPT_VERSION) - Host: $HOST_IP${C_DEFAULT}"
[ "$DRY_RUN" = true ] && log_msg "${C_YELLOW}*** MODALITÀ DRY-RUN ATTIVA (Nessuna modifica reale) ***${C_DEFAULT}"
[ "$SKIP_SNAPSHOT" = true ] && log_msg "${C_YELLOW}*** SNAPSHOT DISABILITATI (--no-snap) ***${C_DEFAULT}"
[ "$CLEAN_MODE" = true ] && log_msg "${C_CYAN}Modalità Pulizia Snapshot attiva.${C_DEFAULT}"

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
            local HOSTNAME=$(pct config "$ID" | grep 'hostname' | awk '{print $2}' || true)
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
    if pct snapshot $ID "$NAME" &>/dev/null; then
        echo "$NAME"
        return 0
    else
        log_status "${C_RED}ERRORE snapshot.${C_DEFAULT}"
        return 1
    fi
}

esegui_rollback() {
    local ID=$1
    local RAW_SNAP=$2
    local CLEAN_SNAP=$(echo "$RAW_SNAP" | grep -o "${SNAP_PREFIX}_[0-9]*_${ID}" | tail -n 1)
    if [ -z "$CLEAN_SNAP" ]; then return 1; fi
    log_status "${C_RED}#### ROLLBACK LXC $ID A $CLEAN_SNAP ####${C_DEFAULT}"
    pct rollback $ID "$CLEAN_SNAP"
    pct start $ID
    pct delsnapshot $ID "$CLEAN_SNAP"
}

aggiorna_stack() {
    local ID=$1
    local PATH_STACK=$2
    local NOME_STACK=$3

    local CHECK=$(esegui_remoto "$ID" "[ -d \"$PATH_STACK\" ] && echo 'ok'")
    [ "$CHECK" != "ok" ] && return 0

    log_status "      Check $NOME_STACK..."

    local RUNNING_BEFORE=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose ps --format '{{.Service}}' --filter \"status=running\" 2>/dev/null" | xargs)
    local PRE_IDS=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose ps -a -q | xargs -r docker inspect --format='{{.Image}}' 2>/dev/null | sed 's/sha256://g' | sort -u | xargs")

    if ! esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose pull -q"; then
        log_status "${C_RED}      ✖ Errore Pull su $NOME_STACK${C_DEFAULT}"
        return 1 
    fi
    
    local POST_IDS=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose config --images 2>/dev/null | xargs -r docker inspect --format='{{.Id}}' 2>/dev/null | sed 's/sha256://g' | sort -u | xargs")

    if [ -n "$POST_IDS" ] && [ "$PRE_IDS" != "$POST_IDS" ]; then
        log_status "${C_GREEN}      ✔ Aggiornamento trovato per $NOME_STACK!${C_DEFAULT}"
        
        if [ "$DRY_RUN" = true ]; then
            UPDATE_LOGS+=("✅ LXC $ID - $NOME_STACK: Disponibile (Dry Run)")
            return 0
        fi

        local UP_OUT=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose up -d 2>&1")
        if [ $? -eq 0 ]; then
            local ALL_SERVICES=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose config --services 2>/dev/null")
            for SERVICE in $ALL_SERVICES; do
                if [[ ! " $RUNNING_BEFORE " =~ " $SERVICE " ]]; then
                    log_status "      ℹ Ripristino stato: fermo $SERVICE..."
                    esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose stop $SERVICE" > /dev/null 2>&1
                fi
            done

            local UPDATED_NAMES=$(echo "$UP_OUT" | grep -E 'Recreated|Started|Created' | sed -E 's/.*Container //;s/ .*//' | sort -u | paste -sd ", " -)
            [ -z "$UPDATED_NAMES" ] && UPDATED_NAMES="Servizi aggiornati"
            UPDATE_LOGS+=("✅ LXC $ID - $NOME_STACK: $UPDATED_NAMES")
            return 0
        else
            log_status "${C_RED}      ✖ Errore Up su $NOME_STACK${C_DEFAULT}"
            return 1
        fi
    else
        UPDATE_LOGS+=("🟡 LXC $ID - $NOME_STACK: Nessuna modifica.")
        return 0
    fi
}

processa_lxc() {
    local ID=$1
    local NOME=$(pct config $ID | grep 'hostname' | awk '{print $2}' || echo "LXC $ID")
    log_msg "--------------------------------------------------------"
    log_msg "${C_CYAN}#### PROCESSO LXC $ID ($NOME) ####${C_DEFAULT}"
    
    [ "$(pct status $ID)" != "status: running" ] && return 0
    
    local SNAP_NAME=""
    if [ "$SKIP_SNAPSHOT" = false ]; then
        SNAP_NAME=$(crea_snapshot $ID)
        [ $? -ne 0 ] && return 1
    fi
    
    local FAILED=false
    for D_PATH in $DOCKGE_PATHS; do
        if ! aggiorna_stack "$ID" "$D_PATH" "Dockge"; then FAILED=true; break; fi
    done
    
    if [ "$FAILED" = false ]; then
        local STACKS=$(esegui_remoto "$ID" "find $SCAN_ROOTS -mindepth 1 -maxdepth 2 -type f -regex \".*\(docker-compose\|compose\).y\(a\)?ml\" -print0 2>/dev/null | xargs -0 -I {} dirname {} | sort -u")
        for P in $STACKS; do
            local SKIP_S=false
            for D in $DOCKGE_PATHS; do [[ "$P" == "$D"* ]] && SKIP_S=true; done
            [ "$SKIP_S" = true ] && continue
            if ! aggiorna_stack "$ID" "$P" "$(basename "$P")"; then FAILED=true; break; fi
        done
    fi

    if [ "$FAILED" = true ]; then
        [ -n "$SNAP_NAME" ] && esegui_rollback "$ID" "$SNAP_NAME"
        UPDATE_LOGS=("${UPDATE_LOGS[@]/%✅ LXC $ID*/❌ LXC $ID - Rollback effettuato}")
        return 1
    fi
    
    if [ "$KEEP_LAST_SNAPSHOT" = true ] && [ -n "$SNAP_NAME" ]; then
        local OLD_SNAPS=$(pct listsnapshot $ID | awk '{print $2}' | grep "^$SNAP_PREFIX" | grep -v "$SNAP_NAME" || true)
        for OS in $OLD_SNAPS; do pct delsnapshot $ID $OS &>/dev/null; done
    fi
    
    esegui_remoto "$ID" "docker image prune -af" >/dev/null
    return 0
}

# ======================================================================
# REPORT E NOTIFICA
# ======================================================================

LXC_IDS=$(trova_lxc_ids "${ARGS[@]}")
[ -z "$LXC_IDS" ] && { echo "Nessun LXC trovato."; exit 1; }

for ID in $LXC_IDS; do processa_lxc "$ID"; done

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
         -d "{\"title\": \"Proxmox Update $(hostname)\", \"message\": \"$JSON_PAYLOAD\"}" \
         "$HA_URL" > /dev/null
    echo "DONE: Processo completato. $UPDATED_COUNT stack aggiornati."
else
    echo -e "\n--- REPORT FINALE ---"
    for E in "${UPDATE_LOGS[@]}"; do
        [[ "$E" == "✅"* ]] && echo -e "${C_GREEN}$E${C_DEFAULT}" || echo -e "${C_YELLOW}$E${C_DEFAULT}"
    done
fi

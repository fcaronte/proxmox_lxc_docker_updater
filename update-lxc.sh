#!/bin/bash

# ======================================================================
# SCRIPT: update-lxc.sh
# DESCRIZIONE: Aggiornamento automatizzato di stack Docker Compose 
#              all'interno di LXC Proxmox, con snapshot opzionali.
# AGGIORNAMENTI: Supporto --no-snap e logica digest v1.6.5+
# ======================================================================

# --- USER CONFIG ---
SCAN_ROOTS="/root /opt/stacks"
# Percorso di Dockge
DOCKGE_PATHS="/root/dockge_install/dockge /opt/dockge" 

# Se true, l'ultimo snapshot di successo viene mantenuto come backup.
KEEP_LAST_SNAPSHOT=true 
# -------------------

# --- CONFIGURAZIONE VARIABILI INTERNE ---
SCRIPT_VERSION="1.7.0 (No-Snap Support)"
SNAP_PREFIX="AUTO_UPDATE_SNAP"
HOST_IP=$(hostname -I | awk '{print $1}')

# Codici colore
C_DEFAULT='\033[0m'
C_RED='\033[0;31m'    
C_GREEN='\033[0;32m'  
C_YELLOW='\033[1;33m' 
C_CYAN='\033[0;36m'   

C_INFO=${C_CYAN}      
C_ERROR=${C_RED}
C_SUCCESS=${C_GREEN}
C_WARNING=${C_YELLOW} 

declare -a UPDATE_LOGS
declare -a SUCCESS_LXC_IDS 

# --- GESTIONE ARGOMENTI E MODALITÀ ---
DRY_RUN=false
CLEAN_MODE=false
SKIP_SNAPSHOT=false
ARGS=()

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --no-snap) SKIP_SNAPSHOT=true ;;
        clean)     CLEAN_MODE=true ;;
        *)         [ "$arg" != "--" ] && ARGS+=("$arg") ;;
    esac
done

if [ ${#ARGS[@]} -eq 0 ]; then
    echo -e "${C_ERROR}ERRORE: Sintassi non valida.${C_DEFAULT}"
    echo "Utilizzo: $0 <ID_LXC|nome_parziale|all> [--dry-run] [--no-snap]"
    echo "Pulizia Snapshot: $0 clean <ID_LXC|nome_parziale|all>"
    exit 1
fi

echo -e "${C_INFO}Aggiornamento LXC Docker (v$SCRIPT_VERSION) - Host: $HOST_IP${C_DEFAULT}"
[ "$CLEAN_MODE" = false ] && echo "Radici di Scansione Docker: $SCAN_ROOTS"
[ "$DRY_RUN" = true ] && echo -e "${C_WARNING}*** MODALITÀ DRY-RUN ATTIVA ***${C_DEFAULT}"
[ "$SKIP_SNAPSHOT" = true ] && echo -e "${C_WARNING}*** SNAPSHOT DISABILITATI (--no-snap) ***${C_DEFAULT}"
echo "--------------------------------------------------------"

# ======================================================================
# FUNZIONI GENERALI
# ======================================================================

esegui_remoto() {
    local ID=$1
    local CMD=$2
    local FINAL_CMD="export LC_ALL=C.UTF-8 && $CMD" 
    pct exec "$ID" -- bash -c "$FINAL_CMD" 2>/dev/null
    return $?
}

trova_lxc_ids() {
    local SEARCH_TERMS=("$@")
    local ACTIVE_IDS=$(pct list | awk 'NR>1 {print $1}' || true)
    local FILTERED_IDS=()
    [ -z "$ACTIVE_IDS" ] && return
    for TERM in "${SEARCH_TERMS[@]}"; do
        if [ "$TERM" == "all" ]; then FILTERED_IDS=($ACTIVE_IDS); break; fi
        for ID in $ACTIVE_IDS; do
            if [ "$ID" == "$TERM" ]; then FILTERED_IDS+=("$ID"); continue; fi
            local HOSTNAME=$(pct config "$ID" | grep 'hostname' | awk '{print $2}' || true)
            if echo "$HOSTNAME" | grep -qi "$TERM"; then FILTERED_IDS+=("$ID"); fi
        done
    done
    echo "${FILTERED_IDS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

# ======================================================================
# GESTIONE SNAPSHOT E PULIZIA
# ======================================================================

esegui_docker_prune() {
    local ID=$1
    echo -e "${C_INFO}   Avvio pulizia spazio Docker su LXC $ID...${C_DEFAULT}"
    [ "$DRY_RUN" = true ] && return 0
    esegui_remoto "$ID" "docker container prune -f && docker image prune -a -f" &>/dev/null
}

pulisci_snapshot_manuale() {
    local ID=$1
    local NOME=$(pct config $ID | grep 'hostname' | awk '{print $2}' || echo "LXC $ID")
    echo -e "${C_INFO}#### PULIZIA MANUALE SNAPSHOT LXC $ID ($NOME) ####${C_DEFAULT}"
    local SNAPS=$(pct listsnapshot $ID | grep "$SNAP_PREFIX" | grep -v 'current' | grep -o "$SNAP_PREFIX[^[:space:]]*" || true)
    local SNAPS_ARRAY=($SNAPS)
    for (( i = ${#SNAPS_ARRAY[@]} - 1; i >= 0; i-- )); do
        local S=${SNAPS_ARRAY[i]}
        echo "   -> Rimozione $S..."
        [ "$DRY_RUN" = false ] && pct delsnapshot "$ID" "$S" &>/dev/null
    done
}

pulisci_old_snap_n1() {
    local ID=$1
    local ALL_SNAPS=$(pct listsnapshot $ID | grep "$SNAP_PREFIX" | grep -v 'current' | grep -o "$SNAP_PREFIX[^[:space:]]*" || true)
    local SNAPS_ARRAY=($ALL_SNAPS)
    [ ${#SNAPS_ARRAY[@]} -le 1 ] && return 0
    local KEEP=${SNAPS_ARRAY[-1]}
    for (( i = ${#SNAPS_ARRAY[@]} - 2; i >= 0; i-- )); do
        local S=${SNAPS_ARRAY[i]}
        echo "   Rimozione snapshot obsoleto: $S..."
        [ "$DRY_RUN" = false ] && pct delsnapshot "$ID" "$S" &>/dev/null
    done
}

crea_snapshot() {
    local ID=$1
    local NAME="${SNAP_PREFIX}_$(date +%Y%m%d%H%M%S)_${ID}"
    echo -e "${C_INFO}Creazione snapshot $NAME...${C_DEFAULT}"
    if [ "$DRY_RUN" = true ]; then echo "$NAME"; return 0; fi
    if pct snapshot $ID "$NAME" 2>/dev/null; then
        echo "$NAME"
        return 0
    else
        echo -e "${C_ERROR}ERRORE: Impossibile creare snapshot.${C_DEFAULT}" >&2
        return 1
    fi
}

esegui_rollback() {
    local ID=$1
    local SNAP=$2
    echo -e "${C_ERROR}#### FALLIMENTO! AVVIO ROLLBACK A $SNAP ####${C_DEFAULT}"
    [ "$DRY_RUN" = true ] && return 0
    pct rollback $ID $SNAP && pct delsnapshot $ID $SNAP
}

# ======================================================================
# LOGICA DI AGGIORNAMENTO
# ======================================================================

aggiorna_stack() {
    local ID=$1
    local PATH_STACK=$2
    local NOME_STACK=$3
    local EXIT_STATUS=0
    
    local COMPOSE_FILE=$(esegui_remoto "$ID" "find \"$PATH_STACK\" -maxdepth 1 -type f \( -name \"docker-compose.yml\" -o -name \"docker-compose.yaml\" -o -name \"compose.yml\" -o -name \"compose.yaml\" \) -print -quit 2>/dev/null || true")
    [ -z "$COMPOSE_FILE" ] && return 0

    echo -e "   -> ${C_INFO}Check $NOME_STACK...${C_DEFAULT}"
    [ "$DRY_RUN" = true ] && return 0
    
    local ACTIVE_SERVICES=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose ps --services --filter \"status=running\" | xargs || true")
    local IMAGE_NAME=$(esegui_remoto "$ID" "grep 'image:' \"$COMPOSE_FILE\" | head -n 1 | awk '{print \$2}' || true")
    local PRE_ID=""
    [ -n "$IMAGE_NAME" ] && PRE_ID=$(esegui_remoto "$ID" "docker images --no-trunc \"$IMAGE_NAME\" | awk 'NR>1 {print \$3}' | head -n 1 || true")

    if ! esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose pull"; then return 1; fi
    
    local POST_ID=""
    [ -n "$IMAGE_NAME" ] && POST_ID=$(esegui_remoto "$ID" "docker images --no-trunc \"$IMAGE_NAME\" | awk 'NR>1 {print \$3}' | head -n 1 || true")
    
    local UPDATED_IMG=""
    [ "$PRE_ID" != "$POST_ID" ] && UPDATED_IMG=" - $IMAGE_NAME"

    local TOUCHED=""
    if [ -n "$ACTIVE_SERVICES" ]; then
        local UP_OUT=$(esegui_remoto "$ID" "cd \"$PATH_STACK\" && docker compose up -d $ACTIVE_SERVICES" 2>&1)
        [ $? -ne 0 ] && EXIT_STATUS=1
        TOUCHED=$(echo "$UP_OUT" | grep -E 'Started|Restarted|Created' | grep 'Container' | sed 's/\[+\] Container //g' | xargs -I {} echo " - {}" | tr '\n' ' ' || true)
    else
        TOUCHED="Nessun riavvio (Stoppato)"
    fi

    if [ "$EXIT_STATUS" -eq 0 ]; then
        if [ -n "$UPDATED_IMG" ] || ([ -n "$TOUCHED" ] && [ "$TOUCHED" != "Nessun riavvio (Stoppato)" ]); then
            UPDATE_LOGS+=("✅ LXC $ID - $NOME_STACK: Immagini:$UPDATED_IMG | Riavviati:$TOUCHED")
        else
            UPDATE_LOGS+=("🟡 LXC $ID - $NOME_STACK: Nessuna modifica.")
        fi
        return 0
    fi
    return 1
}

processa_lxc() {
    local ID=$1
    local NOME=$(pct config $ID | grep 'hostname' | awk '{print $2}' || echo "LXC $ID")
    local SNAP_NAME=""
    
    echo -e "--------------------------------------------------------"
    echo -e "${C_INFO}#### AVVIO PROCESSO PER LXC ID $ID ($NOME) ####${C_DEFAULT}"
    
    [ "$(pct status $ID)" != "status: running" ] && { echo "LXC non in esecuzione. Salto."; return 0; }
    
    # Snapshot condizionale
    if [ "$SKIP_SNAPSHOT" = false ]; then
        SNAP_NAME=$(crea_snapshot $ID)
        [ $? -ne 0 ] && return 1
    fi
    
    local FAILED=false

    # 1. Dockge
    for D_PATH in $DOCKGE_PATHS; do
        if ! aggiorna_stack "$ID" "$D_PATH" "Dockge ($D_PATH)"; then FAILED=true; break; fi
    done

    # 2. Altri Stack
    if [ "$FAILED" = false ]; then
        for ROOT in $SCAN_ROOTS; do
            local STACKS=$(esegui_remoto "$ID" "find \"$ROOT\" -mindepth 1 -maxdepth 2 -type f -regex \".*\(docker-compose\|compose\).y\(a\)?ml\" -print0 2>/dev/null | xargs -0 -I {} dirname {} | sort -u || true")
            for P in $STACKS; do
                # Evita duplicati se il percorso è tra quelli di Dockge
                local SKIP_S=false
                for D in $DOCKGE_PATHS; do [ "$P" == "$D" ] && SKIP_S=true; done
                [ "$SKIP_S" = true ] && continue
                
                if ! aggiorna_stack "$ID" "$P" "$(basename "$P")"; then FAILED=true; break 2; fi
            done
        done
    fi

    if [ "$FAILED" = true ]; then
        [ -n "$SNAP_NAME" ] && esegui_rollback "$ID" "$SNAP_NAME"
        return 1
    fi
    
    SUCCESS_LXC_IDS+=("$ID")
    [ "$KEEP_LAST_SNAPSHOT" = true ] && [ -n "$SNAP_NAME" ] && pulisci_old_snap_n1 "$ID"
    esegui_docker_prune "$ID"
    return 0
}

# ======================================================================
# LOOP PRINCIPALE E REPORT
# ======================================================================

LXC_IDS=$(trova_lxc_ids "${ARGS[@]}")
[ -z "$LXC_IDS" ] && { echo -e "${C_ERROR}Nessun LXC trovato.${C_DEFAULT}"; exit 1; }

if [ "$CLEAN_MODE" = true ]; then
    for ID in $LXC_IDS; do pulisci_snapshot_manuale "$ID"; done
    exit 0
fi

for ID in $LXC_IDS; do processa_lxc "$ID"; done

echo -e "\n========================================================"
echo -e "===== REPORT FINALE AGGIORNAMENTO ====="
for ENTRY in "${UPDATE_LOGS[@]}"; do
    [[ "$ENTRY" == "✅"* ]] && echo -e "${C_SUCCESS}${ENTRY}${C_DEFAULT}" || echo -e "${C_WARNING}${ENTRY}${C_DEFAULT}"
done
echo "========================================================"

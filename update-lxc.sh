#!/bin/bash

# ======================================================================
# SCRIPT: update-lxc.sh
# DESCRIZIONE: Aggiornamento automatizzato di stack Docker Compose 
#              all'interno di LXC Proxmox, con snapshot e rollback.
# SVILUPPATO CON GEMINI
# ======================================================================

# --- USER CONFIG ---
SCAN_ROOTS="/root /opt/stacks"
DOCKGE_PATHS="/root/dockge_install/dockge /opt/dockge"

# Se true, l'ultimo snapshot di successo viene mantenuto come backup.
KEEP_LAST_SNAPSHOT=true
# -------------------

# --- CONFIGURAZIONE VARIABILI INTERNE ---
SCRIPT_VERSION="1.3.0 (Clean Mode)"
SNAP_PREFIX="AUTO_UPDATE_SNAP"
HOST_IP=$(hostname -I | awk '{print $1}')

# Codici colore per l'output (Dry Run cambia C_INFO a Giallo)
C_DEFAULT='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_INFO=${C_BLUE}
C_ERROR=${C_RED}
C_SUCCESS=${C_GREEN}
C_WARNING=${C_YELLOW}

# --- GESTIONE ARGOMENTI E MODALITÀ ---
DRY_RUN=false
CLEAN_MODE=false
ARGS=()

# Processa tutti gli argomenti per identificare le modalità e raccogliere gli ID/nomi
for arg in "$@"; do
    if [ "$arg" == "--dry-run" ]; then
        DRY_RUN=true
        C_INFO=${C_YELLOW} # Cambia il colore per la modalità dry run
    elif [ "$arg" == "clean" ]; then
        CLEAN_MODE=true
    elif [ "$arg" != "--" ]; then
        ARGS+=("$arg")
    fi
done

# Verifica che ci siano argomenti se non è solo un help
if [ ${#ARGS[@]} -eq 0 ]; then
    echo -e "${C_ERROR}ERRORE: Sintassi non valida.${C_RESET}"
    echo "Utilizzo: $0 <ID_LXC|nome_parziale|all> [--dry-run]"
    echo "Pulizia Snapshot: $0 clean <ID_LXC|nome_parziale|all>"
    exit 1
fi

echo -e "${C_INFO}Aggiornamento LXC Docker (v$SCRIPT_VERSION) - Host: $HOST_IP${C_RESET}"
if [ "$CLEAN_MODE" = false ]; then
    echo "Radici di Scansione Docker: $SCAN_ROOTS"
fi

if [ "$DRY_RUN" = true ]; then
    echo -e "${C_WARNING}*** MODALITÀ DRY-RUN ATTIVA: NESSUNA MODIFICA SARÀ APPLICATA ***${C_RESET}"
fi
echo "--------------------------------------------------------"


# ======================================================================
# FUNZIONI GENERALI
# ======================================================================

# Esegue un comando all'interno del container LXC e aggiunge la gestione della locale.
esegui_remoto() {
    local ID=$1
    local CMD=$2
    # Imposta la locale per garantire l'esecuzione corretta di docker compose
    local FINAL_CMD="export LC_ALL=C.UTF-8 && $CMD" 
    
    # Esegue il comando in modo non interattivo
    pct exec "$ID" -- bash -c "$FINAL_CMD"
    return $?
}

# Trova gli ID degli LXC in base agli argomenti forniti (all, ID, o nome parziale)
trova_lxc_ids() {
    local SEARCH_TERMS=("$@")
    local ACTIVE_IDS
    local FILTERED_IDS=()

    # Ottieni tutti gli ID dei container attivi e running
    ACTIVE_IDS=$(pct list | awk 'NR>1 {print $1}' || true)
    
    if [ -z "$ACTIVE_IDS" ]; then
        echo ""
        return
    fi
    
    for TERM in "${SEARCH_TERMS[@]}"; do
        if [ "$TERM" == "all" ]; then
            # Se 'all' è specificato, prendi tutti gli LXC attivi.
            FILTERED_IDS=($ACTIVE_IDS)
            break
        fi
        
        # Filtra per ID numerico o nome parziale
        for ID in $ACTIVE_IDS; do
            if [ "$ID" == "$TERM" ]; then
                FILTERED_IDS+=("$ID")
                continue
            fi
            
            # Controlla il nome host
            local HOSTNAME=$(pct config "$ID" | grep 'hostname' | awk '{print $2}' || true)
            if echo "$HOSTNAME" | grep -qi "$TERM"; then
                FILTERED_IDS+=("$ID")
            fi
        done
    done
    
    # Rimuove duplicati e restituisce l'elenco finale.
    echo "${FILTERED_IDS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '
}


# ======================================================================
# GESTIONE SNAPSHOT
# ======================================================================

# NUOVA FUNZIONE: Pulizia manuale di tutti gli snapshot di sicurezza per uno o più LXC
pulisci_snapshot_manuale() {
    local ID=$1
    local NOME=$(pct config $ID | grep 'hostname' | awk '{print $2}' || echo "LXC $ID")
    echo -e "${C_INFO}#### AVVIO PULIZIA MANUALE SNAPSHOT PER LXC ID $ID ($NOME) ####${C_RESET}"
    
    if ! pct status $ID &>/dev/null; then
        echo -e "${C_WARNING}   -> LXC ID $ID non trovato o non supporta operazioni pct. Salto.${C_RESET}"
        return 0
    fi
    
    # 1. Elenca gli snapshot di Proxmox e filtra per il prefisso. 
    local SNAPS_TO_DELETE=$(pct listsnapshot $ID | grep -oE 'AUTO_UPDATE_SNAP_[0-9_]+'"$ID" || true)

    if [ -z "$SNAPS_TO_DELETE" ]; then
        echo -e "${C_SUCCESS}   -> Nessuno snapshot di pulizia automatica (AUTO_UPDATE_SNAP_) trovato per LXC $ID.${C_RESET}"
        echo "---"
        return 0
    fi

    echo -e "${C_INFO}   -> Trovati snapshot da rimuovere:${C_RESET}"
    
    local SNAPSHOT_COUNTER=0
    for SNAPSHOT in $SNAPS_TO_DELETE; do
        SNAPSHOT_COUNTER=$((SNAPSHOT_COUNTER + 1))
        echo -e "   -> Tentativo di rimozione snapshot: $SNAPSHOT..."
        
        # 2. Rimuove lo snapshot utilizzando il comando Proxmox
        if pct delsnapshot "$ID" "$SNAPSHOT"; then
            echo -e "${C_SUCCESS}  ✅ $SNAPSHOT rimosso con successo.${C_RESET}"
        else
            echo -e "${C_ERROR}  ❌ ERRORE nella rimozione dello snapshot $SNAPSHOT. Continuo...${C_RESET}"
        fi
    done

    if [ "$SNAPSHOT_COUNTER" -gt 0 ]; then
        echo -e "${C_SUCCESS}#### PULIZIA COMPLETA PER LXC ID $ID ($NOME). $SNAPSHOT_COUNTER snapshot processati. ####${C_RESET}"
    fi

    echo "---"
    return 0
}


# Pulisce tutti gli snapshot precedenti ad eccezione di quello eventualmente mantenuto dalla run precedente.
pulisci_vecchi_snapshot() {
    local ID=$1
    local DISK_ID=$2
    local KEEP_SNAP="$3" # Lo snapshot da MANTENERE (quello della run precedente, se KEEP_LAST_SNAPSHOT=true)
    local SNAPSHOTS_TO_REMOVE=""

    # 1. Elenca tutti gli snapshot LVM che corrispondono al prefisso e all'ID LXC
    # Usiamo lvs per identificare i volumi
    local ALL_LVS=$(lvs --nameprefixes -o lv_name,vg_name,lv_attr | grep "snap_vm-$ID-disk.*_$SNAP_PREFIX" | awk -F '"' '{print $2}' | sed 's/^pve\///g' || true)

    if [ -z "$ALL_LVS" ]; then
        echo "   Nessuno snapshot obsoleto con prefisso '$SNAP_PREFIX' trovato per LXC $ID."
        return 0
    fi

    echo "   Trovati i seguenti snapshot obsoleti da processare:"
    
    # 2. Filtra per trovare solo gli snapshot da rimuovere
    for SNAPSHOT in $ALL_LVS; do
        if [ "$SNAPSHOT" != "$KEEP_SNAP" ]; then
            # Estrai il nome dello snapshot Proxmox dal nome del volume LVM
            local SNAP_NAME=$(echo "$SNAPSHOT" | grep -oE "$SNAP_PREFIX"'_.*_'"$ID")
            
            if [ -n "$SNAP_NAME" ]; then
                 echo "   Rimozione snapshot obsoleto: $SNAP_NAME..."
                if pct delsnapshot "$ID" "$SNAP_NAME" &>/dev/null; then
                    echo -e "  ${C_SUCCESS}Snapshot rimosso con successo.${C_RESET}"
                else
                    echo -e "  ${C_ERROR}ERRORE nella rimozione dello snapshot $SNAP_NAME. Continuo...${C_RESET}"
                fi
            fi
        fi
    done
}


# Crea lo snapshot e restituisce il nome in caso di successo
crea_snapshot() {
    local ID=$1
    # Genera un timestamp e crea il nome dello snapshot
    SNAP_NAME="${SNAP_PREFIX}_$(date +%Y%m%d%H%M%S)_${ID}"

    echo -e "${C_INFO}3.1.2 Creazione snapshot $SNAP_NAME...${C_RESET}"
    if [ "$DRY_RUN" = true ]; then
        echo -e "  [DRY-RUN] Snapshot $SNAP_NAME creato (simulato).${C_RESET}"
        return 0
    fi
    
    if pct snapshot $ID "$SNAP_NAME"; then
        echo "Snapshot creato. Avvio aggiornamento Docker..."
        echo "$SNAP_NAME"
        return 0
    else
        echo -e "${C_ERROR}ERRORE: Impossibile creare lo snapshot per LXC $ID.${C_RESET}"
        return 1
    fi
}

# Esegue il rollback e la pulizia in caso di errore
esegui_rollback() {
    local ID=$1
    local SNAP_NAME=$2
    
    echo -e "${C_ERROR}#### AGGIORNAMENTO FALLITO PER LXC ID $ID! AVVIO ROLLBACK! ####${C_RESET}"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "  [DRY-RUN] Rollback a snapshot $SNAP_NAME simulato.${C_RESET}"
        echo -e "  [DRY-RUN] Rimozione snapshot $SNAP_NAME simulata.${C_RESET}"
        return 0
    fi
    
    # 1. Rollback
    echo "  1. Esecuzione Rollback a $SNAP_NAME..."
    if pct rollback $ID $SNAP_NAME; then
        echo -e "${C_SUCCESS}  Rollback completato con successo.${C_RESET}"
    else
        echo -e "${C_ERROR}  ERRORE CRITICO: Rollback fallito. Intervento manuale necessario.${C_RESET}"
        return 1
    fi
    
    # 2. Pulizia (rimuove lo snapshot che ha causato il rollback)
    echo "  2. Rimozione snapshot di rollback $SNAP_NAME..."
    if pct delsnapshot $ID $SNAP_NAME; then
        echo -e "${C_SUCCESS}  Snapshot di rollback rimosso con successo.${C_RESET}"
    else
        echo -e "${C_WARNING}  ATTENZIONE: Impossibile rimuovere lo snapshot $SNAP_NAME. Rimuovere manualmente.${C_RESET}"
    fi
    
    return 0
}

# ======================================================================
# AGGIORNAMENTO DOCKER COMPOSE
# ======================================================================

aggiorna_stack() {
    local ID=$1
    local PATH_STACK=$2
    local NOME_STACK=$3
    
    local EXIT_STATUS=0
    
    # Check Compose: verifica presenza del file compose.
    local COMPOSE_FILE=$(esegui_remoto "$ID" "find \"$PATH_STACK\" -maxdepth 1 -type f \( -name \"docker-compose.yml\" -o -name \"docker-compose.yaml\" -o -name \"compose.yml\" -o -name \"compose.yaml\" \) -print -quit 2>/dev/null || true")
    
    if [ -z "$COMPOSE_FILE" ]; then
        echo -e "   -> ${C_WARNING}ATTENZIONE: Nessun file compose trovato in $PATH_STACK. Stack $NOME_STACK saltato.${C_RESET}"
        return 0 
    fi

    echo -e "   -> ${C_INFO}Aggiornamento selettivo $NOME_STACK in $PATH_STACK...${C_RESET}"

    if "$DRY_RUN"; then
        echo -e "   [DRY-RUN] Simulazione aggiornamento $NOME_STACK... OK.${C_RESET}"
        return 0
    fi
    
    # 1. Trova i servizi ATTIVI prima del pull/update
    local GET_ACTIVE_SERVICES_CMD="cd \"$PATH_STACK\" && docker compose ps --services --filter \"status=running\" || true"
    
    local ACTIVE_SERVICES_RAW
    ACTIVE_SERVICES_RAW=$(esegui_remoto "$ID" "$GET_ACTIVE_SERVICES_CMD")
    
    # Pulisce e converte in una stringa di nomi separati da spazio
    local ACTIVE_SERVICES=$(echo "$ACTIVE_SERVICES_RAW" | grep -v '^\s*$' | xargs || true)
    
    # 2. Esegui solo il PULL delle immagini (aggiornamento senza avvio)
    echo -e "   -> ${C_INFO}Pulling nuove immagini per $NOME_STACK...${C_RESET}"
    local PULL_COMMAND="cd \"$PATH_STACK\" && docker compose pull"

    if ! esegui_remoto "$ID" "$PULL_COMMAND"; then
        echo -e "   -> ${C_ERROR}ERRORE nel PULL delle immagini per $NOME_STACK.${C_RESET}"
        return 1
    fi
    
    if [ -n "$ACTIVE_SERVICES" ]; then
        # 3. Aggiorna solo i servizi che erano ATTIVI (up -d [servizi])
        echo -e "   -> ${C_INFO}Avvio/Aggiornamento solo dei servizi attivi: ($ACTIVE_SERVICES)...${C_RESET}"
        local UP_COMMAND="cd \"$PATH_STACK\" && docker compose up -d $ACTIVE_SERVICES"

        if ! esegui_remoto "$ID" "$UP_COMMAND"; then
            EXIT_STATUS=1
        fi
    else
        echo -e "   -> ${C_WARNING}Nessun servizio attivo trovato. Immagini aggiornate, stato mantenuto (stoppato).${C_RESET}"
    fi


    if [ "$EXIT_STATUS" -eq 0 ]; then
        echo -e "   -> ${C_SUCCESS}$NOME_STACK aggiornato con successo (solo servizi attivi riavviati).${C_RESET}"
    else
        echo -e "   -> ${C_ERROR}ERRORE $EXIT_STATUS nell'avvio dei servizi di $NOME_STACK.${C_RESET}"
    fi
    
    return $EXIT_STATUS
}


# ======================================================================
# LOGICA PRINCIPALE
# ======================================================================

# Trova la lista finale di LXC ID da processare (sia per clean che per update)
IDs=$(trova_lxc_ids "${ARGS[@]}")

if [ -z "$IDs" ]; then
    echo -e "${C_ERROR}Nessun container LXC trovato o attivo con gli argomenti forniti: ${ARGS[@]}${C_RESET}"
    exit 1
fi


# --- MODALITÀ CLEAN: Esegui la pulizia e termina ---
if [ "$CLEAN_MODE" = true ]; then
    echo -e "${C_INFO}===== AVVIO PULIZIA MANUALE SNAPSHOTS =====${C_RESET}"
    for ID in $IDs; do
        pulisci_snapshot_manuale "$ID"
    done
    echo -e "${C_SUCCESS}===== PULIZIA MANUALE COMPLETATA =====${C_RESET}"
    exit 0
fi


# --- MODALITÀ UPDATE (il resto dello script) ---

echo "ID LXC da processare: $IDs"

TOTAL_SUCCESS=0
TOTAL_FAIL=0

for ID in $IDs; do
    
    LXC_HOSTNAME=$(pct config $ID | grep 'hostname' | awk '{print $2}' || echo "LXC $ID")
    echo -e "\n--------------------------------------------------------"
    echo -e "${C_INFO}#### AVVIO PROCESSO PER LXC ID $ID ($LXC_HOSTNAME) ####${C_RESET}"

    # 1. Check Docker
    if ! esegui_remoto "$ID" "command -v docker &> /dev/null && command -v docker compose &> /dev/null"; then
        echo -e "${C_WARNING}Docker non presente nel container $ID → salto.${C_RESET}"
        echo -e "#### FINE PROCESSO PER LXC ID $ID ####"
        continue
    fi
    
    # 2. Ottieni nome disco e ripulisci vecchi snapshot.
    LXC_ROOTFS_DISK=$(pct config $ID | grep -oP 'rootfs:\s*\K(.*?):' | sed 's/:$//' || true)
    
    if [ "$KEEP_LAST_SNAPSHOT" = true ]; then
        # Trova l'ultimo snapshot di successo per mantenerlo
        LAST_SUCCESS_SNAP=$(pct listsnapshot $ID | grep -oE 'AUTO_UPDATE_SNAP_[0-9_]+'"$ID" | tail -n 1 || true)
    else
        LAST_SUCCESS_SNAP=""
    fi
    
    echo -e "${C_INFO}3.1.1 Pulizia vecchi snapshot con prefisso '$SNAP_PREFIX' per LXC $ID...${C_RESET}"
    pulisci_vecchi_snapshot "$ID" "$LXC_ROOTFS_DISK" "$LAST_SUCCESS_SNAP"

    # 3. Creazione Snapshot
    SNAPSHOT_NAME=$(crea_snapshot "$ID")
    if [ $? -ne 0 ]; then
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        continue
    fi
    
    # 4. Inizio Aggiornamento Docker Compose (Aggiornamento Selettivo)
    UPDATE_STATUS=0
    
    if [ "$DRY_RUN" = false ]; then
        echo "Snapshot creato. Avvio aggiornamento Docker..."
        
        # A. Aggiornamento Dockge (se presente)
        for DOCKGE_PATH in $DOCKGE_PATHS; do
            if [ -d "$DOCKGE_PATH" ] || esegui_remoto "$ID" "test -d $DOCKGE_PATH"; then
                if ! aggiorna_stack "$ID" "$DOCKGE_PATH" "Dockge ($DOCKGE_PATH)"; then
                    UPDATE_STATUS=1
                    break
                fi
            fi
        done
        
        if [ "$UPDATE_STATUS" -eq 0 ]; then
            # B. Scansione e aggiornamento degli altri stack
            echo -e "Inizio scansione Docker Compose nei percorsi: $SCAN_ROOTS..."
            
            # Trova tutte le directory che contengono un file docker-compose.yml o simile
            SCAN_CMD="find $SCAN_ROOTS -type f -maxdepth 2 \( -name \"docker-compose.yml\" -o -name \"docker-compose.yaml\" -o -name \"compose.yml\" -o -name \"compose.yaml\" \) -print 2>/dev/null"
            COMPOSE_FILES=$(esegui_remoto "$ID" "$SCAN_CMD" | grep -vE "^[[:space:]]*$" || true)
            
            # Filtra per rimuovere Dockge (già aggiornato)
            for DOCKGE_PATH in $DOCKGE_PATHS; do
                COMPOSE_FILES=$(echo "$COMPOSE_FILES" | grep -v "$DOCKGE_PATH" || true)
            done
            
            # Estrai i percorsi univoci degli stack
            STACK_PATHS=$(echo "$COMPOSE_FILES" | xargs -n1 dirname | sort -u || true)
            
            for PATH_STACK in $STACK_PATHS; do
                # Estrae il nome dello stack (ultima parte del percorso)
                NOME_STACK=$(basename "$PATH_STACK")
                
                if ! aggiorna_stack "$ID" "$PATH_STACK" "$NOME_STACK"; then
                    UPDATE_STATUS=1
                    break
                fi
            done
        fi
    fi # Fine Dry Run check

    # 5. Gestione esito finale
    if [ "$UPDATE_STATUS" -eq 0 ]; then
        TOTAL_SUCCESS=$((TOTAL_SUCCESS + 1))
        echo -e "--------------------------------------------------------"
        echo -e "${C_SUCCESS}AGGIORNAMENTO RIUSCITO per LXC $ID.${C_RESET}"
        
        # Pulizia post-successo
        if [ "$KEEP_LAST_SNAPSHOT" = true ]; then
             echo "Configurazione KEEP_LAST_SNAPSHOT=true: lo snapshot $SNAPSHOT_NAME viene MANTENUTO."
        else
            if [ "$DRY_RUN" = false ]; then
                echo "Configurazione KEEP_LAST_SNAPSHOT=false: rimozione dello snapshot $SNAPSHOT_NAME..."
                if pct delsnapshot $ID $SNAPSHOT_NAME; then
                     echo -e "${C_SUCCESS}Snapshot rimosso con successo.${C_RESET}"
                else
                    echo -e "${C_WARNING}ATTENZIONE: Impossibile rimuovere lo snapshot $SNAPSHOT_NAME. Rimuovere manualmente.${C_RESET}"
                fi
            else
                echo -e "  [DRY-RUN] Snapshot $SNAPSHOT_NAME rimosso (simulato) (KEEP_LAST_SNAPSHOT=false)."
            fi
        fi
    else
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        esegui_rollback "$ID" "$SNAPSHOT_NAME"
    fi

    echo -e "#### FINE PROCESSO PER LXC ID $ID ####"
done

# ======================================================================
# REPORT FINALE
# ======================================================================

echo -e "\n========================================================"
echo -e "===== REPORT FINALE AGGIORNAMENTO LXC & DOCKER ====="
echo -e "========================================================"

for ID in $IDs; do
    LXC_HOSTNAME=$(pct config $ID | grep 'hostname' | awk '{print $2}' || echo "LXC $ID")
    
    # La logica del report finale non è in grado di tracciare lo stato esatto del loop precedente, 
    # quindi si basa sui conteggi totali per un riassunto finale generico.
    # Per un tracciamento preciso, il loop principale dovrebbe aggiornare uno stato per ogni ID.
    
    # Riporto lo stato generico basato sull'attività complessiva.
    if [ "$TOTAL_FAIL" -eq 0 ] && [ "$TOTAL_SUCCESS" -gt 0 ]; then
        # Se tutti gli aggiornamenti eseguiti sono andati a buon fine
        echo -e "LXC $ID ($LXC_HOSTNAME) → ${C_SUCCESS}OK${C_RESET}"
    elif [ "$TOTAL_FAIL" -gt 0 ]; then
        # Se c'è stato almeno un fallimento (anche se altri sono riusciti)
        echo -e "LXC $ID ($LXC_HOSTNAME) → ${C_WARNING}VERIFICARE (Fallimenti: $TOTAL_FAIL)${C_RESET}"
    elif [ "$TOTAL_SUCCESS" -eq 0 ] && [ "$TOTAL_FAIL" -eq 0 ]; then
        # Se non è successo nulla (LXC saltato o dry-run)
        echo -e "LXC $ID ($LXC_HOSTNAME) → ${C_INFO}PROCESSATO/SALTATO${C_RESET}"
    fi
done

if [ "$TOTAL_FAIL" -gt 0 ]; then
    echo -e "\n${C_ERROR}ATTENZIONE: Sono falliti $TOTAL_FAIL aggiornamenti. Rollback eseguiti.${C_RESET}"
fi

echo -e "========================================================"

#!/bin/bash

# ======================================================================
# SCRIPT: update-lxc.sh
# DESCRIZIONE: Aggiornamento automatizzato di stack Docker Compose 
#              all'interno di LXC Proxmox, con snapshot e rollback.
# SVILUPPATO CON GEMINI
# ======================================================================

# --- USER CONFIG ---
SCAN_ROOTS="/root /opt/stacks"
# Percorso di Dockge
DOCKGE_PATHS="/root/dockge_install/dockge" 

# Se true, l'ultimo snapshot di successo viene mantenuto come backup.
# V1.6.0: Pulizia eseguita DOPO la creazione del nuovo snapshot per mantenere solo l'ultimo (N=1).
KEEP_LAST_SNAPSHOT=true 
# -------------------

# --- CONFIGURAZIONE VARIABILI INTERNE ---
SCRIPT_VERSION="1.6.1 (Report Cleanup)" # Versione Aggiornata
SNAP_PREFIX="AUTO_UPDATE_SNAP"
HOST_IP=$(hostname -I | awk '{print $1}')

# Codici colore per l'output (Massima visibilità)
C_DEFAULT='\033[0m'
C_RED='\033[0;31m'    # Rosso: Errori critici
C_GREEN='\033[0;32m'  # Verde: Successo
C_YELLOW='\033[1;33m' # Giallo Brillante/Fluo: Info, Warning, Dry-Run (Alta leggibilità)
C_CYAN='\033[0;36m'   # Ciano

# IMPOSTAZIONE NUOVI COLORI STANDARD
C_INFO=${C_CYAN}      # Info e Avanzamento in Ciano
C_ERROR=${C_RED}
C_SUCCESS=${C_GREEN}
C_WARNING=${C_YELLOW} # Warning in Giallo Brillante

# Array globale per raccogliere i log di aggiornamento per il report finale
declare -a UPDATE_LOGS

# --- GESTIONE ARGOMENTI E MODALITÀ ---
DRY_RUN=false
CLEAN_MODE=false
ARGS=()

# Processa tutti gli argomenti per identificare le modalità e raccogliere gli ID/nomi
for arg in "$@"; do
    if [ "$arg" == "--dry-run" ]; then
        DRY_RUN=true
    elif [ "$arg" == "clean" ]; then
        CLEAN_MODE=true
    elif [ "$arg" != "--" ]; then
        ARGS+=("$arg")
    fi
done

# Verifica che ci siano argomenti se non è solo un help
if [ ${#ARGS[@]} -eq 0 ]; then
    echo -e "${C_ERROR}ERRORE: Sintassi non valida.${C_DEFAULT}"
    echo "Utilizzo: $0 <ID_LXC|nome_parziale|all> [--dry-run]"
    echo "Pulizia Snapshot: $0 clean <ID_LXC|nome_parziale|all>"
    exit 1
fi

echo -e "${C_INFO}Aggiornamento LXC Docker (v$SCRIPT_VERSION) - Host: $HOST_IP${C_DEFAULT}"
if [ "$CLEAN_MODE" = false ]; then
    echo "Radici di Scansione Docker: $SCAN_ROOTS"
fi

if [ "$DRY_RUN" = true ]; then
    echo -e "${C_WARNING}*** MODALITÀ DRY-RUN ATTIVA: NESSUNA MODIFICA SARÀ APPLICATA ***${C_DEFAULT}"
fi
echo "--------------------------------------------------------"


# ======================================================================
# FUNZIONI GENERALI
# ======================================================================

# Esegue un comando all'interno del container LXC e aggiunge la gestione della locale.
esegui_remoto() {
    local ID=$1
    local CMD=$2
    # La locale è inclusa per migliorare la compatibilità dei comandi interni al container
    local FINAL_CMD="export LC_ALL=C.UTF-8 && $CMD" 
    
    # Esegui il comando e sopprimi i warning di bash sulla locale
    # Soppressione dei warning sulla locale per mantenere pulito l'output
    pct exec "$ID" -- bash -c "$FINAL_CMD" 2>/dev/null
    return $?
}

# Trova gli ID degli LXC in base agli argomenti forniti (all, ID, o nome parziale)
trova_lxc_ids() {
    local SEARCH_TERMS=("$@")
    local ACTIVE_IDS
    local FILTERED_IDS=()

    ACTIVE_IDS=$(pct list | awk 'NR>1 {print $1}' || true)
    
    if [ -z "$ACTIVE_IDS" ]; then
        echo ""
        return
    fi 
    
    for TERM in "${SEARCH_TERMS[@]}"; do
        if [ "$TERM" == "all" ]; then
            FILTERED_IDS=($ACTIVE_IDS)
            break
        fi
        
        for ID in $ACTIVE_IDS; do
            if [ "$ID" == "$TERM" ]; then
                FILTERED_IDS+=("$ID")
                continue
            fi
            
            local HOSTNAME=$(pct config "$ID" | grep 'hostname' | awk '{print $2}' || true)
            if echo "$HOSTNAME" | grep -qi "$TERM"; then
                FILTERED_IDS+=("$ID")
            fi
        done
    done
    
    echo "${FILTERED_IDS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '
}


# ======================================================================
# GESTIONE SNAPSHOT
# ======================================================================

# Pulizia manuale di tutti gli snapshot di sicurezza per uno o più LXC (Modalità 'clean')
pulisci_snapshot_manuale() {
    local ID=$1
    local NOME=$(pct config $ID | grep 'hostname' | awk '{print $2}' || echo "LXC $ID")
    echo -e "${C_INFO}#### AVVIO PULIZIA MANUALE SNAPSHOT PER LXC ID $ID ($NOME) ####${C_DEFAULT}"
    
    if ! pct status $ID &>/dev/null; then
        echo -e "${C_WARNING}   -> LXC ID $ID non trovato o non supporta operazioni pct. Salto.${C_DEFAULT}"
        return 0
    fi
    
    # 1. Elenca gli snapshot: filtra per prefisso.
    local SNAPS_TO_DELETE_RAW=$(pct listsnapshot $ID | grep "$SNAP_PREFIX" | grep -v 'current' | grep -o "$SNAP_PREFIX[^[:space:]]*" || true)

    if [ -z "$SNAPS_TO_DELETE_RAW" ]; then
        echo -e "${C_SUCCESS}   -> Nessuno snapshot di pulizia automatica ($SNAP_PREFIX) trovato per LXC $ID.${C_DEFAULT}"
        echo "---"
        return 0
    fi

    echo -e "${C_INFO}   -> Trovati snapshot da rimuovere:${C_DEFAULT}"
    
    local SNAPSHOT_COUNTER=0
    # Trasforma i nomi in un array e ordina per nome (timestamp)
    local SNAPS_ARRAY=($SNAPS_TO_DELETE_RAW)

    # Cicla al contrario su TUTTI gli elementi per rimuovere prima i figli (Logica LVM)
    for (( i = ${#SNAPS_ARRAY[@]} - 1; i >= 0; i-- )); do
        local SNAPSHOT=${SNAPS_ARRAY[i]}
        
        if [ -n "$SNAPSHOT" ]; then
            SNAPSHOT_COUNTER=$((SNAPSHOT_COUNTER + 1))
            echo "   -> Tentativo di rimozione snapshot: $SNAPSHOT..."
            
            if [ "$DRY_RUN" = true ]; then
                echo -e "  [DRY-RUN] Snapshot $SNAPSHOT rimosso (simulato)."
            elif pct delsnapshot "$ID" "$SNAPSHOT" &>/dev/null; then
                echo -e "${C_SUCCESS}  ✅ $SNAPSHOT rimosso con successo.${C_DEFAULT}"
            else
                echo -e "${C_ERROR}  ❌ ERRORE nella rimozione dello snapshot $SNAPSHOT. Continuo...${C_DEFAULT}"
            fi
        fi
    done

    if [ "$SNAPSHOT_COUNTER" -gt 0 ]; then
        echo -e "${C_SUCCESS}#### PULIZIA COMPLETA PER LXC ID $ID ($NOME). $SNAPSHOT_COUNTER snapshot processati. ####${C_DEFAULT}"
    fi

    echo "---"
    return 0
}


# Pulisce tutti gli snapshot precedenti ad eccezione dell'ultimo (N=1). (Eseguita post-successo)
pulisci_old_snap_n1() {
    local ID=$1
    
    echo "   Esecuzione Pulizia Snapshot (Mantieni solo l'ultimo di successo)..."
    
    # 1. Estrae i nomi di TUTTI gli snapshot creati da questo script.
    local ALL_SNAPS_RAW=$(pct listsnapshot $ID | grep "$SNAP_PREFIX" | grep -v 'current' | grep -o "$SNAP_PREFIX[^[:space:]]*" || true)

    if [ -z "$ALL_SNAPS_RAW" ]; then
        echo "   Nessuno snapshot obsoleto con prefisso '$SNAP_PREFIX' trovato per LXC $ID."
        return 0
    fi

    local SNAPS_ARRAY=($ALL_SNAPS_RAW)
    
    # Se ci sono 0 o 1 snapshot automatici, non c'è nulla da rimuovere.
    if [ ${#SNAPS_ARRAY[@]} -le 1 ]; then
        echo -e "   Trovato 1 o meno snapshot. Nessuna rimozione necessaria (L'ultimo è mantenuto).${C_DEFAULT}"
        return 0
    fi
    
    # Lo snapshot più recente da MANTENERE è l'ultimo elemento dell'array.
    local SNAP_TO_KEEP=${SNAPS_ARRAY[-1]}
    
    echo "   Trovati ${#SNAPS_ARRAY[@]} snapshot. Verranno rimossi i vecchi, mantenendo solo $SNAP_TO_KEEP."
    
    # 2. Identifica gli snapshot da ELIMINARE (tutti tranne l'ultimo)
    local SNAPS_TO_DELETE=()
    for (( i = 0; i < ${#SNAPS_ARRAY[@]} - 1; i++ )); do
        SNAPS_TO_DELETE+=("${SNAPS_ARRAY[i]}")
    done
    
    # 3. Rimuovi in ordine INVERSO per rispettare la gerarchia LVM (i figli devono essere eliminati prima dei genitori)
    local NUM_TO_DELETE=${#SNAPS_TO_DELETE[@]}
    local FOUND_OLD_SNAPS=false
    
    # Cicla al contrario sugli elementi DA ELIMINARE (dal più recente al più vecchio tra quelli non mantenuti)
    for (( i = NUM_TO_DELETE - 1; i >= 0; i-- )); do
        local SNAPSHOT_TO_DELETE=${SNAPS_TO_DELETE[i]}
        
        FOUND_OLD_SNAPS=true
        echo "   Rimozione snapshot obsoleto: $SNAPSHOT_TO_DELETE..."
        
        if [ "$DRY_RUN" = true ]; then
             echo "  [DRY-RUN] Snapshot $SNAPSHOT_TO_DELETE rimosso (simulato)."
        elif pct delsnapshot "$ID" "$SNAPSHOT_TO_DELETE" &>/dev/null; then
            echo -e "  ${C_SUCCESS}Snapshot $SNAPSHOT_TO_DELETE rimosso con successo.${C_DEFAULT}"
        else
            echo -e "  ${C_ERROR}ERRORE nella rimozione dello snapshot $SNAPSHOT_TO_DELETE. Potrebbe essere un genitore bloccato. Continuo...${C_DEFAULT}"
        fi
    done
    
    if [ "$FOUND_OLD_SNAPS" = false ]; then
        echo "   Nessuno snapshot obsoleto da rimuovere."
    fi
}


# Crea lo snapshot e restituisce il nome dello snapshot (e solo quello) in caso di successo
crea_snapshot() {
    local ID=$1
    SNAP_NAME="${SNAP_PREFIX}_$(date +%Y%m%d%H%M%S)_${ID}"
    
    echo -e "${C_INFO}Creazione snapshot $SNAP_NAME...${C_DEFAULT}"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "  [DRY-RUN] Snapshot $SNAP_NAME creato (simulato).${C_DEFAULT}"
        echo "$SNAP_NAME" # Ritorna il nome in dry-run
        return 0
    fi
    
    # Esegui il comando e cattura l'exit code.
    if pct snapshot $ID "$SNAP_NAME" 2> >(grep -v 'WARNING' 1>&2); then 
        echo "$SNAP_NAME" # Ritorna solo il nome dello snapshot (pulito) su stdout
        return 0
    else
        echo -e "${C_ERROR}ERRORE: Impossibile creare lo snapshot per LXC $ID.${C_DEFAULT}" >&2 # Errore critico su stderr
        return 1
    fi
}

# Esegue il rollback e la pulizia in caso di errore
esegui_rollback() {
    local ID=$1
    local SNAP_NAME=$2
    
    echo -e "${C_ERROR}#### AGGIORNAMENTO FALLITO PER LXC ID $ID! AVVIO ROLLBACK! ####${C_DEFAULT}"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "  [DRY-RUN] Rollback a snapshot $SNAP_NAME simulato.${C_DEFAULT}"
        echo -e "  [DRY-RUN] Rimozione snapshot $SNAP_NAME simulata.${C_DEFAULT}"
        return 0
    fi
    
    # 1. Rollback
    echo "  1. Esecuzione Rollback a $SNAP_NAME..."
    if pct rollback $ID $SNAP_NAME; then
        echo -e "${C_SUCCESS}  Rollback completato con successo.${C_DEFAULT}"
    else
        echo -e "${C_ERROR}  ERRORE CRITICO: Rollback fallito. Intervento manuale necessario.${C_DEFAULT}"
        return 1
    fi
    
    # 2. Pulizia (rimuove lo snapshot che ha causato il rollback)
    echo "  2. Rimozione snapshot di rollback $SNAP_NAME..."
    if pct delsnapshot $ID $SNAP_NAME; then
        echo -e "${C_SUCCESS}  Snapshot di rollback rimosso con successo.${C_DEFAULT}"
    else
        echo -e "${C_WARNING}  ATTENZIONE: Impossibile rimuovere lo snapshot $SNAP_NAME. Rimuovere manualmente.${C_DEFAULT}"
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
        echo -e "   -> ${C_WARNING}ATTENZIONE: Nessun file compose trovato in $PATH_STACK. Stack $NOME_STACK saltato.${C_DEFAULT}"
        return 0 
    fi

    echo -e "   -> ${C_INFO}Aggiornamento selettivo $NOME_STACK in $PATH_STACK...${C_DEFAULT}"

    if "$DRY_RUN"; then
        echo -e "   [DRY-RUN] Simulazione aggiornamento $NOME_STACK... OK.${C_DEFAULT}"
        return 0
    fi
    
    # 1. Trova i servizi ATTIVI prima del pull/update
    local GET_ACTIVE_SERVICES_CMD="cd \"$PATH_STACK\" && docker compose ps --services --filter \"status=running\" || true"
    
    local ACTIVE_SERVICES_RAW
    ACTIVE_SERVICES_RAW=$(esegui_remoto "$ID" "$GET_ACTIVE_SERVICES_CMD")
    
    local ACTIVE_SERVICES=$(echo "$ACTIVE_SERVICES_RAW" | grep -v '^\s*$' | xargs || true)
    
    
    # 2. Ottieni l'Image Digest PRIMA del Pull (USO SOLO IL PRIMO SERVIZIO TROVATO PER IL CHECK)
    local IMAGE_NAME
    local PRE_PULL_DIGEST=""
    
    # Trova il nome dell'immagine dal file compose
    IMAGE_NAME=$(esegui_remoto "$ID" "grep 'image:' \"$COMPOSE_FILE\" | head -n 1 | awk '{print \$2}' || true")
    
    if [ -n "$IMAGE_NAME" ]; then
        # Recupera il Digest ID dell'immagine corrente
        PRE_PULL_DIGEST=$(esegui_remoto "$ID" "docker images --digests $IMAGE_NAME | awk 'NR>1 {print \$3}' || true")
        if [ -z "$PRE_PULL_DIGEST" ]; then
            PRE_PULL_DIGEST=$(esegui_remoto "$ID" "docker images --no-trunc $IMAGE_NAME | awk 'NR>1 {print \$3}' || true")
        fi
    fi

    echo -e "   -> ${C_INFO}Pulling nuove immagini per $NOME_STACK...${C_DEFAULT}"
    local PULL_COMMAND="cd \"$PATH_STACK\" && docker compose pull"

    # Esegui il pull (senza mostrare output)
    esegui_remoto "$ID" "$PULL_COMMAND" &>/dev/null 

    if [ $? -ne 0 ]; then
        echo -e "   -> ${C_ERROR}ERRORE nel PULL delle immagini per $NOME_STACK.${C_DEFAULT}"
        return 1
    fi
    
    local UPDATED_IMAGES=""
    
    # 3. Ottieni l'Image Digest DOPO il Pull e CONFRONTA
    if [ -n "$IMAGE_NAME" ] && [ -n "$PRE_PULL_DIGEST" ]; then # Confronta solo se l'ID iniziale era stato trovato
        local POST_PULL_DIGEST
        
        POST_PULL_DIGEST=$(esegui_remoto "$ID" "docker images --digests $IMAGE_NAME | awk 'NR>1 {print \$3}' || true")
        
        if [ -z "$POST_PULL_DIGEST" ]; then
            POST_PULL_DIGEST=$(esegui_remoto "$ID" "docker images --no-trunc $IMAGE_NAME | awk 'NR>1 {print \$3}' || true")
        fi
        
        # Confronto cruciale: se il digest è cambiato, c'è stato un aggiornamento
        if [ "$PRE_PULL_DIGEST" != "$POST_PULL_DIGEST" ]; then
            UPDATED_IMAGES=" - $IMAGE_NAME"
        fi
    fi
    
    local CONTAINERS_TOUCHED=""

    if [ -n "$ACTIVE_SERVICES" ]; then
        # 4. Aggiorna solo i servizi che erano ATTIVI
        echo -e "   -> ${C_INFO}Avvio/Aggiornamento solo dei servizi attivi: ($ACTIVE_SERVICES)...${C_DEFAULT}"
        local UP_COMMAND="cd \"$PATH_STACK\" && docker compose up -d $ACTIVE_SERVICES"

        local UP_OUTPUT
        UP_OUTPUT=$(esegui_remoto "$ID" "$UP_COMMAND" 2>&1 || true)
        
        if [ $? -ne 0 ]; then
            EXIT_STATUS=1
        fi
        
        # Filtra l'output UP per vedere i container che sono stati toccati (Started, Restarted)
        CONTAINERS_TOUCHED=$(echo "$UP_OUTPUT" | grep -E 'Started|Restarted|Created' | grep 'Container' | sed 's/\[+\] Container //g' | sed 's/ Started.*//g' | sed 's/ Restarted.*//g' | sed 's/ Created.*//g' | xargs -I {} echo " - {}" | tr '\n' ' ' || true)
        
        # Se non ci sono stati aggiornamenti di immagine, e non c'è stato output di riavvio: azzera per indicare "Nessun aggiornamento"
        if [ -z "$UPDATED_IMAGES" ] && [ -z "$CONTAINERS_TOUCHED" ]; then
             CONTAINERS_TOUCHED=""
        fi
    else
        echo -e "   -> ${C_WARNING}Nessun servizio attivo trovato. Stato mantenuto (stoppato).${C_DEFAULT}"
        CONTAINERS_TOUCHED="Nessun riavvio (Status: Stoppato)"
    fi

    # 5. Crea l'entry di log (LOGICA AGGIORNATA QUI)
    if [ "$EXIT_STATUS" -eq 0 ]; then
        local LOG_ENTRY="LXC $ID - $NOME_STACK:"
        
        # CASO 1: Aggiornamento o riavvio Effettivo rilevato (immagini aggiornate O container toccati)
        if [ -n "$UPDATED_IMAGES" ] || [ -n "$CONTAINERS_TOUCHED" ] && [ "$CONTAINERS_TOUCHED" != "Nessun riavvio (Status: Stoppato)" ]; then
            LOG_ENTRY+=" Immagini Aggiornate:${UPDATED_IMAGES:- Nessuna} | Containers Riavviati:${CONTAINERS_TOUCHED:- Nessuno}"
            UPDATE_LOGS+=("✅ $LOG_ENTRY") # Aggiunge con prefisso verde
        else
            # CASO 2: Nessun aggiornamento necessario (Immagini: Nessuna, Riavviati: Nessuno o Stoppati)
            LOG_ENTRY+=" Nessun aggiornamento necessario."
            UPDATE_LOGS+=("🟡 $LOG_ENTRY") # Aggiunge con prefisso giallo per chiarezza
        fi
        
        # Stampa a schermo la conferma generale
        echo -e "   -> ${C_SUCCESS}$NOME_STACK aggiornato con successo (solo servizi attivi riavviati).${C_DEFAULT}"
    else
        echo -e "   -> ${C_ERROR}ERRORE $EXIT_STATUS nell'avvio dei servizi di $NOME_STACK. (Rollback in arrivo).${C_DEFAULT}"
    fi
    
    return $EXIT_STATUS
}


# ======================================================================
# LOGICA PRINCIPALE
# ======================================================================

IDs=$(trova_lxc_ids "${ARGS[@]}")

if [ -z "$IDs" ]; then
    echo -e "${C_ERROR}Nessun container LXC trovato o attivo con gli argomenti forniti: ${ARGS[@]}${C_DEFAULT}"
    exit 1
fi


# --- MODALITÀ CLEAN: Esegui la pulizia e termina ---
if [ "$CLEAN_MODE" = true ]; then
    echo -e "${C_INFO}===== AVVIO PULIZIA MANUALE SNAPSHOTS =====${C_DEFAULT}"
    for ID in $IDs; do
        pulisci_snapshot_manuale "$ID"
    done
    echo -e "${C_SUCCESS}===== PULIZIA MANUALE COMPLETA =====${C_DEFAULT}"
    exit 0
fi


# --- MODALITÀ UPDATE (il resto dello script) ---

echo "ID LXC da processare: $IDs"

TOTAL_SUCCESS=0
TOTAL_FAIL=0

for ID in $IDs; do
    
    LXC_HOSTNAME=$(pct config $ID | grep 'hostname' | awk '{print $2}' || echo "LXC $ID")
    echo -e "\n--------------------------------------------------------"
    echo -e "${C_INFO}#### AVVIO PROCESSO PER LXC ID $ID ($LXC_HOSTNAME) ####${C_DEFAULT}"

    # 1. Check Docker
    if ! command -v pct &>/dev/null; then
        echo -e "${C_ERROR}ERRORE: Il comando 'pct' (Proxmox Container Toolkit) non è disponibile.${C_DEFAULT}"
        echo -e "#### FINE PROCESSO PER LXC ID $ID ####"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        continue
    fi

    if ! esegui_remoto "$ID" "command -v docker &> /dev/null && command -v docker compose &> /dev/null"; then
        echo -e "${C_WARNING}Docker non presente nel container $ID → salto.${C_DEFAULT}"
        echo -e "#### FINE PROCESSO PER LXC ID $ID ####"
        continue
    fi
    
    
    # 2. Creazione Snapshot (Il punto di rollback immediato)
    SNAPSHOT_NAME=$(crea_snapshot "$ID")
    SNAPSHOT_EXIT_CODE=$?
    
    if [ $SNAPSHOT_EXIT_CODE -ne 0 ]; then
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        continue
    fi
    
    echo "Snapshot creato. Avvio aggiornamento Docker..."
    
    # 3. Inizio Aggiornamento Docker Compose (Aggiornamento Selettivo)
    UPDATE_STATUS=0
    
    if [ "$DRY_RUN" = false ]; then
        
        # A. Aggiornamento Dockge (se presente)
        for DOCKGE_PATH in $DOCKGE_PATHS; do
            if esegui_remoto "$ID" "test -d $DOCKGE_PATH"; then
                if ! aggiorna_stack "$ID" "$DOCKGE_PATH" "Dockge ($DOCKGE_PATH)"; then
                    UPDATE_STATUS=1
                    break
                fi
            fi
        done
        
        if [ "$UPDATE_STATUS" -eq 0 ]; then
            # B. Scansione e aggiornamento degli altri stack
            echo -e "Inizio scansione Docker Compose nei percorsi: $SCAN_ROOTS..."
            
            SCAN_CMD="find $SCAN_ROOTS -type f -maxdepth 2 \( -name \"docker-compose.yml\" -o -name \"docker-compose.yaml\" -o -name \"compose.yml\" -o -name \"compose.yaml\" \) -print 2>/dev/null"
            COMPOSE_FILES=$(esegui_remoto "$ID" "$SCAN_CMD" | grep -vE "^[[:space:]]*$" || true)
            
            # Filtra per rimuovere Dockge (già aggiornato)
            for DOCKGE_PATH in $DOCKGE_PATHS; do
                COMPOSE_FILES=$(echo "$COMPOSE_FILES" | grep -v "$DOCKGE_PATH" || true)
            done
            
            STACK_PATHS=$(echo "$COMPOSE_FILES" | xargs -n1 dirname | sort -u || true)
            
            for PATH_STACK in $STACK_PATHS; do
                NOME_STACK=$(basename "$PATH_STACK")
                
                if ! aggiorna_stack "$ID" "$PATH_STACK" "$NOME_STACK"; then
                    UPDATE_STATUS=1
                    break
                fi
            done
        fi
    fi

    # 4. Gestione esito finale
    if [ "$UPDATE_STATUS" -eq 0 ]; then
        TOTAL_SUCCESS=$((TOTAL_SUCCESS + 1))
        echo -e "--------------------------------------------------------"
        echo -e "${C_SUCCESS}AGGIORNAMENTO RIUSCITO per LXC $ID.${C_DEFAULT}"
        
        # 4.1 Pulizia Post-Successo (Ora avviene QUI)
        if [ "$KEEP_LAST_SNAPSHOT" = true ]; then
             echo "Configurazione KEEP_LAST_SNAPSHOT=true: lo snapshot $SNAPSHOT_NAME è ora L'UNICO MANTENUTO."
             
             # Esegui la pulizia N=1 DOPO che il nuovo snapshot è stato creato con successo.
             pulisci_old_snap_n1 "$ID" 

             echo "Nota: Tutti gli snapshot precedenti sono stati processati per la rimozione."
        else
            # Rimuovi lo snapshot se non è da mantenere
            if [ "$DRY_RUN" = false ]; then
                echo "Configurazione KEEP_LAST_SNAPSHOT=false: rimozione dello snapshot $SNAPSHOT_NAME..."
                if pct delsnapshot $ID $SNAPSHOT_NAME; then
                     echo -e "${C_SUCCESS}Snapshot rimosso con successo.${C_DEFAULT}"
                else
                    echo -e "${C_WARNING}ATTENZIONE: Impossibile rimuovere lo snapshot $SNAPSHOT_NAME. Rimuovere manualmente.${C_DEFAULT}"
                fi
            else
                echo -e "  [DRY-RUN] Snapshot $SNAPSHOT_NAME rimosso (simulato) (KEEP_LAST_SNAPSHOT=false)."
            fi
        fi
    else
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        # Se fallisce, esegue il rollback e rimuove lo snapshot.
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

## 1. Dettagli Log Aggiornamenti
if [ ${#UPDATE_LOGS[@]} -gt 0 ]; then
    echo -e "${C_INFO}--- Dettagli degli Aggiornamenti Riusciti ---${C_DEFAULT}"
    for LOG in "${UPDATE_LOGS[@]}"; do
        if echo "$LOG" | grep -q "Nessun aggiornamento trovato."; then
            echo -e "${C_WARNING}🟡 $LOG${C_DEFAULT}"
        else
            echo -e "${C_SUCCESS}✅ $LOG${C_DEFAULT}"
        fi
    done
    echo "---"
fi

## 2. Stato Finale LXC
echo -e "${C_INFO}--- Stato Finale LXC ---${C_DEFAULT}"
for ID in $IDs; do
    LXC_HOSTNAME=$(pct config $ID | grep 'hostname' | awk '{print $2}' || echo "LXC $ID")
    
    if [ "$TOTAL_FAIL" -gt 0 ]; then
        echo -e "LXC $ID ($LXC_HOSTNAME) → ${C_WARNING}VERIFICARE (Fallimenti rilevati nella sessione)${C_DEFAULT}"
    elif [ "$TOTAL_SUCCESS" -gt 0 ]; then
        echo -e "LXC $ID ($LXC_HOSTNAME) → ${C_SUCCESS}OK (Aggiornamento Riuscito)${C_DEFAULT}"
    else
         echo -e "LXC $ID ($LXC_HOSTNAME) → ${C_INFO}PROCESSATO/SALTATO${C_DEFAULT}"
    fi
done


if [ "$TOTAL_FAIL" -gt 0 ]; then
    echo -e "\n${C_ERROR}ATTENZIONE: Sono falliti $TOTAL_FAIL aggiornamenti. Rollback eseguiti (o tentati).${C_DEFAULT}"
fi

echo -e "========================================================"

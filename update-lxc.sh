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
DOCKGE_PATHS="/root/dockge_install/dockge /opt/dockge" 

# Se true, l'ultimo snapshot di successo viene mantenuto come backup.
# V1.6.0: Pulizia eseguita DOPO la creazione del nuovo snapshot per mantenere solo l'ultimo (N=1).
KEEP_LAST_SNAPSHOT=true 
# -------------------

# --- CONFIGURAZIONE VARIABILI INTERNE ---
SCRIPT_VERSION="1.6.4 (Report Fix)" # Versione Aggiornata
SNAP_PREFIX="AUTO_UPDATE_SNAP"
HOST_IP=$(hostname -I | awk '{print $1}')

# Codici colore per l'output (Massima visibilità)
C_DEFAULT='\033[0m'
C_RED='\033[0;31m'    
C_GREEN='\033[0;32m'  
C_YELLOW='\033[1;33m' 
C_CYAN='\033[0;36m'   

# IMPOSTAZIONE NUOVI COLORI STANDARD
C_INFO=${C_CYAN}      
C_ERROR=${C_RED}
C_SUCCESS=${C_GREEN}
C_WARNING=${C_YELLOW} 

# Array globali per raccogliere i log e gli ID di successo
declare -a UPDATE_LOGS
declare -a SUCCESS_LXC_IDS # Nuovo array per tracciare gli ID che hanno avuto successo

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
# GESTIONE PULIZIA
# ======================================================================

# Funzione NUOVA: Pulizia di Container e Immagini Docker non utilizzati
esegui_docker_prune() {
    local ID=$1
    echo -e "${C_INFO}   Avvio pulizia spazio Docker (Immagini/Container non utilizzati) su LXC $ID...${C_DEFAULT}"

    if [ "$DRY_RUN" = true ]; then
        echo -e "   [DRY-RUN] Pulizia immagini e container simulata.${C_DEFAULT}"
        return 0
    fi
    
    # Rimuove container stoppati e immagini non usate. NON tocca i volumi per sicurezza.
    local PRUNE_CMD="docker container prune -f && docker image prune -a -f"

    # Esegui il comando in remoto e sopprimi l'output verbose di prune
    if esegui_remoto "$ID" "$PRUNE_CMD" &>/dev/null; then
        echo -e "${C_SUCCESS}   Pulizia Docker System completata.${C_DEFAULT}"
    else
        echo -e "${C_WARNING}   ATTENZIONE: Pulizia Docker System non riuscita o fallita in parte.${C_DEFAULT}"
    fi
}


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

    # Esegui il pull (MOSTRANDO output per feedback visivo)
    if ! esegui_remoto "$ID" "$PULL_COMMAND"; then
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


# Esegue l'aggiornamento di Dockge (percorso specifico)
aggiorna_dockge() {
    local ID=$1
    local DOCKGE_PATH=$2
    
    # Aggiorna SEMPRE il percorso passato come argomento
    aggiorna_stack "$ID" "$DOCKGE_PATH" "Dockge ($DOCKGE_PATH)"
}


# La funzione principale che gestisce lo stato e il loop di aggiornamento per un LXC
processa_lxc() {
    local ID=$1
    local NOME=$(pct config $ID | grep 'hostname' | awk '{print $2}' || echo "LXC $ID")
    local SNAP_NAME=""
    local AGGIORNAMENTO_RIUSCITO=false
    
    echo -e "--------------------------------------------------------"
    echo -e "${C_INFO}#### AVVIO PROCESSO PER LXC ID $ID ($NOME) ####${C_DEFAULT}"
    
    # 1. Check stato e pre-requisiti
    if ! pct status $ID &>/dev/null; then
        echo -e "${C_ERROR}ERRORE: LXC ID $ID non trovato.${C_DEFAULT}"
        return 1
    fi
    
    local LXC_STATUS=$(pct status $ID)
    if [ "$LXC_STATUS" != "status: running" ]; then
        echo -e "${C_WARNING}ATTENZIONE: LXC $ID è $LXC_STATUS. Aggiornamento saltato.${C_DEFAULT}"
        return 0
    fi
    
    # 2. Creazione Snapshot (Prima fase)
    local SNAP_RESULT
    SNAP_RESULT=$(crea_snapshot $ID)
    local SNAP_EXIT_CODE=$?
    
    if [ $SNAP_EXIT_CODE -ne 0 ]; then
        echo -e "${C_ERROR}Procedura interrotta a causa dell'errore di snapshot.${C_DEFAULT}"
        return 1
    fi
    
    SNAP_NAME=$(echo "$SNAP_RESULT" | tail -n 1) # Assicura che sia solo il nome
    echo "Snapshot creato. Avvio aggiornamento Docker..."
    
    # 3. Aggiornamento Docker Compose
    
    # A. Aggiorna Dockge (se configurato)
    for DOCKGE_PATH in $DOCKGE_PATHS; do
        aggiorna_dockge "$ID" "$DOCKGE_PATH"
        if [ $? -ne 0 ]; then
            esegui_rollback "$ID" "$SNAP_NAME"
            return 1
        fi
    done
    
    # B. Scansione e Aggiornamento altri stack
    echo "Inizio scansione Docker Compose nei percorsi: $SCAN_ROOTS..."
    local DOCKGE_PATHS_ARRAY=($DOCKGE_PATHS) # Converti i percorsi Dockge in un array per la ricerca
    
    for ROOT in $SCAN_ROOTS; do
        local STACK_PATHS
        # Trova cartelle che contengono file compose al primo livello (-maxdepth 2)
        STACK_PATHS=$(esegui_remoto "$ID" "find \"$ROOT\" -mindepth 1 -maxdepth 2 -type f -regex \".*\(docker-compose\|compose\).y\(a\)?ml\" -print0 2>/dev/null | xargs -0 -I {} dirname {} | sort -u || true")
        
        for PATH_STACK in $STACK_PATHS; do
            local STACK_NAME=$(basename "$PATH_STACK")
            
            # Salta Dockge se è già stato aggiornato (ora usa l'array)
            local IS_DOCKGE=false
            for DOCKGE_PATH in "${DOCKGE_PATHS_ARRAY[@]}"; do
                if [ "$PATH_STACK" == "$DOCKGE_PATH" ]; then
                    IS_DOCKGE=true
                    break
                fi
            done
            
            if [ "$IS_DOCKGE" = true ]; then
                continue 
            fi
            
            aggiorna_stack "$ID" "$PATH_STACK" "$STACK_NAME"
            
            if [ $? -ne 0 ]; then
                esegui_rollback "$ID" "$SNAP_NAME"
                return 1
            fi
        done
    done
    
    # 4. Aggiornamento Riuscito (Gestione finale)
    AGGIORNAMENTO_RIUSCITO=true
    # Aggiungi l'ID all'array di successo
    SUCCESS_LXC_IDS+=("$ID")
    
    echo -e "--------------------------------------------------------"
    echo -e "${C_SUCCESS}AGGIORNAMENTO RIUSCITO per LXC $ID.${C_DEFAULT}"
    
    # 5. Pulizia Snapshot (Se richiesto)
    if [ "$KEEP_LAST_SNAPSHOT" = true ] && [ "$AGGIORNAMENTO_RIUSCITO" = true ]; then
        # ATTENZIONE: La logica di pulizia $N=1 deve essere chiamata dopo aver creato il nuovo snapshot.
        echo "Configurazione KEEP_LAST_SNAPSHOT=true: lo snapshot Creazione snapshot $SNAP_NAME..."
        echo -e "${C_CYAN}$SNAP_NAME è ora L'UNICO MANTENUTO.${C_DEFAULT}"
        pulisci_old_snap_n1 "$ID"
    fi
    
    # 6. Pulizia Docker System (NUOVA FASE)
    if [ "$AGGIORNAMENTO_RIUSCITO" = true ]; then
        esegui_docker_prune "$ID"
    fi

    echo "Nota: Tutti gli snapshot precedenti sono stati processati per la rimozione."
    echo -e "${C_INFO}#### FINE PROCESSO PER LXC ID $ID ####${C_DEFAULT}"
    
    return 0
}


# ======================================================================
# LOOP PRINCIPALE
# ======================================================================

# Trova gli ID da processare
LXC_IDS=$(trova_lxc_ids "${ARGS[@]}")

if [ -z "$LXC_IDS" ]; then
    echo -e "${C_ERROR}ERRORE: Nessun LXC trovato o ID/nome non valido: ${ARGS[*]}${C_DEFAULT}"
    exit 1
fi

echo "ID LXC da processare: $LXC_IDS"
echo -e "\n--------------------------------------------------------"


# Gestione modalità CLEAN (solo pulizia snapshot, senza aggiornamento)
if [ "$CLEAN_MODE" = true ]; then
    echo -e "${C_INFO}===== AVVIO PULIZIA MANUALE SNAPSHOTS =====${C_DEFAULT}"
    for ID in $LXC_IDS; do
        pulisci_snapshot_manuale "$ID"
    done
    echo -e "${C_SUCCESS}===== PULIZIA MANUALE COMPLETA =====${C_DEFAULT}"
    exit 0
fi

# Loop di aggiornamento
for ID in $LXC_IDS; do
    processa_lxc "$ID"
done

# ======================================================================
# REPORT FINALE
# ======================================================================
echo -e "\n========================================================"
echo -e "===== REPORT FINALE AGGIORNAMENTO LXC & DOCKER ====="
echo -e "========================================================"

echo "--- Dettagli degli Aggiornamenti Riusciti ---"
if [ ${#UPDATE_LOGS[@]} -eq 0 ]; then
    echo "Nessun log di aggiornamento da mostrare."
else
    for ENTRY in "${UPDATE_LOGS[@]}"; do
        # Stampa l'entry con il colore del prefisso (✅=verde, 🟡=giallo)
        case "$ENTRY" in
            "✅ "* )
                echo -e "${C_SUCCESS}${ENTRY}${C_DEFAULT}"
                ;;
            "🟡 "* )
                echo -e "${C_WARNING}${ENTRY}${C_DEFAULT}"
                ;;
            * )
                echo "$ENTRY"
                ;;
        esac
    done
fi
echo "---"

echo "--- Stato Finale LXC ---"

# Usa l'array SUCCESS_LXC_IDS per determinare lo stato del risultato
LXC_SUCCESS_MAP=$(for ID in "${SUCCESS_LXC_IDS[@]}"; do echo "$ID"; done)

for ID in $LXC_IDS; do
    LXC_STATUS=$(pct status $ID 2>/dev/null)
    NOME=$(pct config $ID 2>/dev/null | grep 'hostname' | awk '{print $2}' || echo "LXC $ID")
    
    if echo "$LXC_STATUS" | grep -q "running"; then
        if [[ " ${LXC_SUCCESS_MAP[@]} " =~ " $ID " ]]; then
            # L'ID è nell'array di successo
            echo -e "${C_SUCCESS}LXC $ID ($NOME) → OK (Aggiornamento Riuscito)${C_DEFAULT}"
        else
            # L'LXC è attivo, ma l'aggiornamento è stato saltato (es. era 'stoppato' prima)
            echo -e "${C_WARNING}LXC $ID ($NOME) → OK (Aggiornamento Saltato/Precedente)${C_DEFAULT}"
        fi
    else
        # L'LXC non è attivo
        echo -e "${C_ERROR}LXC $ID ($NOME) → ERRORE/Stoppato ($LXC_STATUS)${C_DEFAULT}"
    fi
done
echo "========================================================"
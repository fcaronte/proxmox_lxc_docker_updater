#!/bin/bash
set -euo pipefail
# =================================================================
# SCRIPT: AGGIORNAMENTO SICURO LXC E DOCKER
# VERSIONE 48 (FINALE CON PULIZIA SNAPSHOT E AGGIORNAMENTO SELETTIVO)
# =================================================================

# --- 0. CONFIGURAZIONE DI BASE E VARIABILI GLOBALI ---
C_SUCCESS='\e[32m'
C_ERROR='\e[31m'
C_WARNING='\e[33m'
C_INFO='\e[36m' 
C_RESET='\e[0m'

# Prefisso costante per gli snapshot gestiti dallo script
SNAPSHOT_PREFIX="AUTO_UPDATE_SNAP"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

# =================================================================
#               CONFIGURAZIONE UTENTE (USER CONFIG)
# =================================================================

# 1. RADICI DI SCANSIONE DOCKER (MULTI-PATH SUPPORTATO): 
#    Directory nell'LXC dove cercare gli stack compose (separati da spazio).
SCAN_ROOTS="/root /opt/stacks"

# 2. PERCORSI DOCKGE (MULTI-PATH SUPPORTATO): 
#    Percorsi delle installazioni di Dockge (separati da spazio).
DOCKGE_PATHS="/root/dockge_install/dockge /opt/dockge" 

# 3. MANTIENI L'ULTIMO SNAPSHOT (Keep Last Snapshot)
#    Se 'true', l'ultimo snapshot di successo NON viene cancellato (NUOVA LOGICA).
KEEP_LAST_SNAPSHOT=true 

# =================================================================

# Variabili di stato
REPORT=()
DRY_RUN=false

# --- FUNZIONE AUSILIARIA PER ESECUZIONE REMOTA ---

esegui_remoto() {
    local ID=$1
    local CMD=$2
    
    # MANTENUTA LA FORZATURA LOCALE C.UTF-8 (potrebbe generare warning se non installata)
    local FINAL_CMD="export LC_ALL=C.UTF-8 && $CMD"
    
    if "$DRY_RUN"; then
        echo -e "   [DRY-RUN] pct exec $ID -- bash -c \"$FINAL_CMD\""
        return 0 
    else
        /usr/sbin/pct exec "$ID" -- bash -c "$FINAL_CMD"
    fi
}

# --- FUNZIONE DI AGGIORNAMENTO (AGGIORNATA PER LOGICA SELETTIVA) ---

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
    
    # 1. Trova i servizi ATTIVI prima del pull/update (usa --services per ottenere solo i nomi)
    local GET_ACTIVE_SERVICES_CMD="cd \"$PATH_STACK\" && docker compose ps --services --filter \"status=running\" || true"
    
    # Eseguo il comando per ottenere l'elenco dei servizi attivi.
    local ACTIVE_SERVICES_RAW
    ACTIVE_SERVICES_RAW=$(esegui_remoto "$ID" "$GET_ACTIVE_SERVICES_CMD")
    
    # Converto la lista in una stringa di nomi di servizi separati da spazio
    local ACTIVE_SERVICES=$(echo "$ACTIVE_SERVICES_RAW" | tr '\n' ' ' | sed 's/ $//' || true)
    
    # 2. Esegui solo il PULL delle immagini (aggiornamento senza avvio)
    local PULL_COMMAND="cd \"$PATH_STACK\" && docker compose pull"

    if ! esegui_remoto "$ID" "$PULL_COMMAND"; then
        echo -e "   -> ${C_ERROR}ERRORE nel PULL delle immagini per $NOME_STACK.${C_RESET}"
        return 1
    fi
    
    local UP_COMMAND=""
    
    if [ -n "$ACTIVE_SERVICES" ]; then
        # 3. Aggiorna solo i servizi che erano ATTIVI (up -d <servizi>)
        echo -e "   -> ${C_INFO}Avvio/Aggiornamento solo dei servizi attivi: ($ACTIVE_SERVICES)...${C_RESET}"
        UP_COMMAND="cd \"$PATH_STACK\" && docker compose up -d $ACTIVE_SERVICES"

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


# --- 1. GESTIONE DEI PARAMETRI E DELLA PAROLA CHIAVE 'ALL' ---

LXC_INPUT=()
# Raccoglie i parametri, gestendo il flag --dry-run
for param in "$@"; do
    if [[ "$param" == "--dry-run" ]]; then
        DRY_RUN=true
    else
        LXC_INPUT+=( "$param" )
    fi
done

LXC_IDS=()

if [ ${#LXC_INPUT[@]} -eq 0 ]; then
    echo -e "${C_ERROR}ERRORE: Nessun ID o nome LXC specificato (usa 'all' per tutti). Uscita.${C_RESET}"
    exit 1
fi

if "$DRY_RUN"; then
    echo -e "${C_WARNING}*** MODALITÀ DRY-RUN ATTIVA: NESSUNA MODIFICA SARÀ APPLICATA ***${C_RESET}"
fi

if [ "${LXC_INPUT[0]}" = "all" ]; then
    echo -e "${C_INFO}Rilevata parola chiave 'all'. Scansione di tutti i container LXC attivi...${C_RESET}"
    
    LXC_IDS=( $(/usr/sbin/pct list | awk 'NR>1 {print $1}' | while read ID; do 
        STATUS=$(/usr/sbin/pct status $ID)
        if [[ "$STATUS" == "status: running" ]]; then
            echo "$ID"
        fi
    done) )
else
    # Processa ogni input: ID, Nome, o Nomi Multipli
    for INPUT_VAL in "${LXC_INPUT[@]}"; do
        if [[ "$INPUT_VAL" =~ ^[0-9]+$ ]]; then
            LXC_IDS+=( "$INPUT_VAL" )
        else
            echo -e "${C_INFO}Ricerca ID per nome LXC: $INPUT_VAL (match parziale multiplo)...${C_RESET}"
            
            MATCHED_IDS_RAW=$(/usr/sbin/pct list | tail -n +2 | grep -i "$INPUT_VAL" | awk '{print $1}')

            if [ -n "$MATCHED_IDS_RAW" ]; then
                MATCHED_IDS=()
                readarray -t MATCHED_IDS <<< "$MATCHED_IDS_RAW"
                
                MATCH_COUNT=0
                for ID in "${MATCHED_IDS[@]}"; do
                    if [[ "$ID" =~ ^[0-9]+$ ]]; then
                        STATUS=$(/usr/sbin/pct status "$ID")
                        if [[ "$STATUS" == "status: running" ]]; then
                            NAME=$(/usr/sbin/pct config $ID | grep 'hostname' | awk '{print $2}' || echo "Sconosciuto")
                            echo -e "${C_SUCCESS}Trovato e aggiunto LXC $ID ($NAME).${C_RESET}"
                            LXC_IDS+=( "$ID" )
                            MATCH_COUNT=$((MATCH_COUNT + 1))
                        else
                            NAME=$(/usr/sbin/pct config $ID | grep 'hostname' | awk '{print $2}' || echo "Sconosciuto")
                            echo -e "${C_WARNING}Trovato LXC $ID ($NAME), ma non è in stato 'running'. Saltato.${C_RESET}"
                        fi
                    fi
                done

                if [ "$MATCH_COUNT" -eq 0 ]; then
                    echo -e "${C_ERROR}ERRORE: Nessun LXC attivo trovato con match parziale '$INPUT_VAL'. Saltato.${C_RESET}"
                fi

            else
                echo -e "${C_ERROR}ERRORE: Nessun LXC con match parziale o ID '$INPUT_VAL' trovato. Saltato.${C_RESET}"
            fi
        fi
    done
fi

LXC_IDS=( $(printf "%s\n" "${LXC_IDS[@]}" | sort -u) )

if [ ${#LXC_IDS[@]} -eq 0 ]; then
    echo -e "${C_ERROR}ERRORE: Nessun ID LXC valido o attivo da processare. Uscita.${C_RESET}"
    exit 1
fi

echo -e "${C_INFO}ID LXC da processare: ${LXC_IDS[@]}${C_RESET}"
echo -e "${C_INFO}Radici di Scansione Docker: $SCAN_ROOTS${C_RESET}"
echo "--------------------------------------------------------"

# --- 3. LOOP SU OGNI CONTAINER LXC ---

for LXC_ID in "${LXC_IDS[@]}"; do
    echo -e "${C_INFO}#### AVVIO PROCESSO PER LXC ID $LXC_ID ####${C_RESET}"
    
    # 3.0 CONTROLLO DOCKER
    if ! esegui_remoto "$LXC_ID" "which docker" >/dev/null 2>&1; then
        echo -e "${C_WARNING}Docker non presente nel container $LXC_ID → salto.${C_RESET}"
        REPORT+=("${C_WARNING}LXC $LXC_ID → SALTATO (Docker non presente)${C_RESET}")
        echo -e "${C_INFO}#### FINE PROCESSO PER LXC ID $LXC_ID ####${C_RESET}"
        echo ""
        continue
    fi
    
    # --- 3.1 GESTIONE E CREAZIONE DELLO SNAPSHOT PROXMOX ---
    
    SNAPSHOT_NAME="${SNAPSHOT_PREFIX}_$(date +%Y%m%d%H%M%S)_$LXC_ID"

    if "$DRY_RUN"; then
        echo -e "${C_WARNING}[DRY-RUN] Snapshot: Pulizia precedente e creazione simulata di $SNAPSHOT_NAME.${C_RESET}"
    else
        # 1. Pulizia Vecchi Snapshot Gestiti (RIMOZIONE DI TUTTA LA CATENA PRECEDENTE)
        echo -e "${C_INFO}3.1.1 Pulizia vecchi snapshot con prefisso '${SNAPSHOT_PREFIX}' per LXC $LXC_ID...${C_RESET}"
        
        # CORREZIONE FINALE: Usa grep per isolare le righe e awk per estrarre il NOME DELLO SNAPSHOT ($2)
        OLD_SNAPS=( $(/usr/sbin/pct listsnapshot "$LXC_ID" | grep "${SNAPSHOT_PREFIX}_" | awk '{print $2}' || true) )
        
        if [ ${#OLD_SNAPS[@]} -eq 0 ]; then
            echo -e "   Nessun snapshot precedente da rimuovere."
        else
            for OLD_SNAP in "${OLD_SNAPS[@]}"; do
                echo -e "${C_WARNING}   Rimozione snapshot obsoleto: $OLD_SNAP...${C_RESET}"
                /usr/sbin/pct delsnapshot "$LXC_ID" "$OLD_SNAP"
            done
        fi

        # 2. Creazione Nuovo Snapshot
        echo -e "${C_INFO}3.1.2 Creazione snapshot $SNAPSHOT_NAME...${C_RESET}"
        if ! /usr/sbin/pct snapshot "$LXC_ID" "$SNAPSHOT_NAME" --description "Snapshot prima aggiornamento Docker $LXC_ID (Gestito da script)"; then
            echo -e "${C_ERROR}ERRORE CRITICO: impossibile creare lo snapshot per LXC $LXC_ID.${C_RESET}"
            echo -e "${C_WARNING}Salto l'aggiornamento per motivi di sicurezza.${C_RESET}"
            REPORT+=("${C_ERROR}LXC $LXC_ID → ERRORE CRITICO (Snapshot fallito)${C_RESET}")
            echo -e "${C_INFO}#### FINE PROCESSO PER LXC ID $LXC_ID ####${C_RESET}"
            echo ""
            continue
        fi
        echo -e "${C_INFO}Snapshot creato. Avvio aggiornamento Docker...${C_RESET}"
    fi

    # --- 3.2 ESECUZIONE AGGIORNAMENTO DOCKER (Sequenza) ---
    TOTAL_STATUS=0
    
    # 1. Aggiorna gli Stack Dockge (LOOP SU PERCORSI MULTIPLI)
    for DOCKGE_PATH in $DOCKGE_PATHS; do
        if ! aggiorna_stack "$LXC_ID" "$DOCKGE_PATH" "Dockge ($DOCKGE_PATH)"; then
            TOTAL_STATUS=$((TOTAL_STATUS + 1))
        fi
    done
    
    # 2. Scansione e Aggiornamento degli Stack Generici (LOOP SU PERCORSI MULTIPLI)
    echo -e "${C_INFO}Inizio scansione Docker Compose nei percorsi: $SCAN_ROOTS...${C_RESET}"
    
    STACKS_FOUND=()
    
    # Costruisci l'elenco degli esclusi (Dockge) per il comando FIND
    EXCLUDE_DOCKGE_PATHS=""
    for DOCKGE_PATH in $DOCKGE_PATHS; do
        EXCLUDE_DOCKGE_PATHS+=" -path \"$DOCKGE_PATH\" -prune -o"
    done
    EXCLUDE_DOCKGE_PATHS=$(echo "$EXCLUDE_DOCKGE_PATHS" | xargs)

    # Costruisci il comando FIND (ora con esclusione)
    SCAN_COMMAND="find $SCAN_ROOTS \
        -path \"*/proc\" -prune -o \
        -path \"*/sys\" -prune -o \
        -path \"*/dev\" -prune -o \
        -path \"*/tmp\" -prune -o \
        $EXCLUDE_DOCKGE_PATHS \
        -type f \\( -name \"docker-compose.yml\" -o -name \"docker-compose.yaml\" -o -name \"compose.yml\" -o -name \"compose.yaml\" \\) -print0 2>/dev/null \
        | xargs -0 dirname || true"
    
    STACK_PATHS_OUTPUT=""
    if "$DRY_RUN"; then
        echo -e "   [DRY-RUN] PCT exec per la Scansione degli Stack (non eseguito):"
        echo "   $SCAN_COMMAND"
    else
        STACK_PATHS_OUTPUT=$(esegui_remoto "$LXC_ID" "$SCAN_COMMAND")
    fi

    if [ -n "$STACK_PATHS_OUTPUT" ]; then
        STACK_PATHS_OUTPUT=$(echo "$STACK_PATHS_OUTPUT" | tr ' ' '\n' | sort -u | grep -v '^\s*$' || true)
        readarray -t STACKS_FOUND <<< "$STACK_PATHS_OUTPUT"
    fi

    if [ ${#STACKS_FOUND[@]} -eq 0 ]; then
        echo -e "${C_INFO}Nessun altro stack Docker Compose trovato nei percorsi specificati (esclusi Dockge).${C_RESET}"
    else
        for STACK_PATH in "${STACKS_FOUND[@]}"; do
            STACK_NAME=$(basename "$STACK_PATH")
            if ! aggiorna_stack "$LXC_ID" "$STACK_PATH" "$STACK_NAME"; then
                TOTAL_STATUS=$((TOTAL_STATUS + 1))
            fi
        done
    fi
    
    echo "--------------------------------------------------------"

    # --- 3.3 GESTIONE ESITO E RIPRISTINO/PULIZIA ---
    
    if "$DRY_RUN"; then
        REPORT+=("${C_WARNING}LXC $LXC_ID → DRY-RUN COMPLETATO (Nessuna modifica applicata)${C_RESET}")

    elif [ "$TOTAL_STATUS" -eq 0 ]; then
        # *** AGGIORNAMENTO RIUSCITO ***
        echo -e "${C_SUCCESS}AGGIORNAMENTO RIUSCITO per LXC $LXC_ID.${C_RESET}"
        
        if [ "$KEEP_LAST_SNAPSHOT" = true ]; then
            echo -e "${C_INFO}Configurazione KEEP_LAST_SNAPSHOT=true: lo snapshot $SNAPSHOT_NAME viene MANTENUTO.${C_RESET}"
            REPORT+=("${C_SUCCESS}LXC $LXC_ID → OK (Snapshot mantenuto)${C_RESET}")
        else
            echo -e "${C_INFO}Rimuovo lo snapshot temporaneo $SNAPSHOT_NAME...${C_RESET}"
            /usr/sbin/pct delsnapshot "$LXC_ID" "$SNAPSHOT_NAME"
            echo -e "${C_INFO}Pulizia completata.${C_RESET}"
            REPORT+=("${C_SUCCESS}LXC $LXC_ID → OK (Snapshot rimosso - Vecchia Logica)${C_RESET}")
        fi

    else
        # *** ERRORE DURANTE L'AGGIORNAMENTO (ROLLBACK) ***
        echo -e "${C_ERROR}ERRORE DURANTE L'AGGIORNAMENTO di LXC $LXC_ID! Codice Totale: $TOTAL_STATUS${C_RESET}"
        echo -e "${C_WARNING}Eseguo il ROLLBACK allo snapshot $SNAPSHOT_NAME...${C_RESET}"
        
        if ! /usr/sbin/pct rollback "$LXC_ID" "$SNAPSHOT_NAME"; then
            echo -e "${C_ERROR}ERRORE CRITICO: Fallito il rollback. Richiesta attenzione manuale su $LXC_ID!${C_RESET}"
            REPORT+=("${C_ERROR}LXC $LXC_ID → ERRORE FATALE (Rollback fallito!)${C_RESET}")
        else
            echo -e "${C_SUCCESS}Ripristino LXC $LXC_ID completato. Stato precedente ripristinato.${C_RESET}"
            
            # Lo snapshot fallito viene sempre rimosso dopo il rollback.
            echo -e "${C_INFO}Rimuovo lo snapshot fallito/usato $SNAPSHOT_NAME...${C_RESET}"
            /usr/sbin/pct delsnapshot "$LXC_ID" "$SNAPSHOT_NAME"
            echo -e "${C_INFO}Pulizia completata.${C_RESET}"
            REPORT+=("${C_WARNING}LXC $LXC_ID → ROLLBACK ESEGUITO (Codice errore: $TOTAL_STATUS)${C_RESET}")
        fi
    fi
    echo -e "${C_INFO}#### FINE PROCESSO PER LXC ID $LXC_ID ####${C_RESET}"
    echo ""
done

# --- 4. REPORT FINALE ---
echo ""
echo "========================================================"
echo -e "${C_INFO}===== REPORT FINALE AGGIORNAMENTO LXC & DOCKER =====${C_RESET}"
echo "========================================================"
printf "%b\n" "${REPORT[@]}"
echo "========================================================"

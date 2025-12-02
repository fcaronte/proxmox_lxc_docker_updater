#!/bin/bash
set -euo pipefail
# =================================================================
# SCRIPT: AGGIORNAMENTO SICURO LXC E DOCKER
# VERSIONE 47: SUPPORTO MULTI-CARTELLA
# =================================================================

# --- 0. CONFIGURAZIONE DI BASE E COLORI ---
C_SUCCESS='\e[32m'
C_ERROR='\e[31m'
C_WARNING='\e[33m'
C_INFO='\e[36m' 
C_RESET='\e[0m'

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

# =================================================================
#               CONFIGURAZIONE UTENTE (USER CONFIG)
# =================================================================

# 1. RADICI DI SCANSIONE DOCKER (MULTI-PATH SUPPORTATO): 
#    Directory nell'LXC dove cercare gli stack compose (separati da spazio).
#    ESEMPIO: Se hai stack in /root e /opt:
SCAN_ROOTS="/root /opt/stacks"

# 2. PERCORSI DOCKGE (MULTI-PATH SUPPORTATO): 
#    Percorsi delle installazioni di Dockge (separati da spazio).
#    Questi vengono aggiornati per primi ed ESCLUSI dalla scansione generale.
#    ESEMPIO: Se hai due istanze Dockge:
DOCKGE_PATHS="/root/dockge_install/dockge /opt/dockge" 

# =================================================================

# Variabili di stato
REPORT=()
DRY_RUN=false

# --- FUNZIONE AUSILIARIA PER ESECUZIONE REMOTA (LOCALE INIETTATA) ---

# Esegue un comando all'interno dell'LXC specificato, forzando la locale C.UTF-8 
# per garantire che i comandi interni non falliscano falsamente.
esegui_remoto() {
    local ID=$1
    local CMD=$2
    
    # MANTENUTA LA FORZATURA LOCALE PER FUNZIONALIT�
    local FINAL_CMD="export LC_ALL=C.UTF-8 && $CMD"
    
    if "$DRY_RUN"; then
        echo -e "   [DRY-RUN] pct exec $ID -- bash -c \"$FINAL_CMD\""
        # Usato echo per coerenza di output, ma lo status deve sempre essere 0 in Dry Run
        return 0 
    else
        # Esegue il comando e cattura lo status
        /usr/sbin/pct exec "$ID" -- bash -c "$FINAL_CMD"
    fi
}

# --- 2. FUNZIONE DI AGGIORNAMENTO (Esecuzione Inline Protetta) ---

aggiorna_stack() {
    local ID=$1
    local PATH_STACK=$2
    local NOME_STACK=$3
    
    local EXIT_CODE=1
    
    # Check Compose: verifica presenza del file compose.
    local CHECK_COMMAND="test -f \"$PATH_STACK/docker-compose.yml\" || test -f \"$PATH_STACK/docker-compose.yaml\" || test -f \"$PATH_STACK/compose.yml\" || test -f \"$PATH_STACK/compose.yaml\""

    # Usa esegui_remoto per il check. In DRY_RUN, assume successo se non fallisce subito.
    if ! esegui_remoto "$ID" "$CHECK_COMMAND" >/dev/null 2>&1; then
        echo -e "   -> ${C_WARNING}ATTENZIONE: Nessun file compose trovato in $PATH_STACK. Stack $NOME_STACK saltato.${C_RESET}"
        return 0 
    fi

    echo -e "   -> ${C_INFO}Aggiornamento $NOME_STACK in $PATH_STACK...${C_RESET}"

    if "$DRY_RUN"; then
        echo -e "   [DRY-RUN] Simulazione aggiornamento $NOME_STACK... OK.${C_RESET}"
        return 0
    fi
    
    # Aggiornamento standard: pull & up -d
    local UPDATE_COMMAND="cd \"$PATH_STACK\" && docker compose pull && docker compose up -d"

    # Usa esegui_remoto per l'aggiornamento.
    if esegui_remoto "$ID" "$UPDATE_COMMAND"; then
        EXIT_CODE=0
    else
        EXIT_CODE=$?
    fi

    if [ "$EXIT_CODE" -eq 0 ]; then
        echo -e "   -> ${C_SUCCESS}$NOME_STACK aggiornato con successo.${C_RESET}"
    else
        echo -e "   -> ${C_ERROR}ERRORE $EXIT_CODE nell'aggiornamento di $NOME_STACK.${C_RESET}"
    fi
    
    return $EXIT_CODE 
}

# --- 1. GESTIONE DEI PARAMETRI E DELLA PAROLA CHIAVE 'ALL' (NON MODIFICATA) ---

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
    echo -e "${C_WARNING}*** MODALIT� DRY-RUN ATTIVA: NESSUNA MODIFICA SAR� APPLICATA ***${C_RESET}"
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
                            echo -e "${C_WARNING}Trovato LXC $ID ($NAME), ma non � in stato 'running'. Saltato.${C_RESET}"
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
        echo -e "${C_WARNING}Docker non presente nel container $LXC_ID  salto.${C_RESET}"
        REPORT+=("${C_WARNING}LXC $LXC_ID  SALTATO (Docker non presente)${C_RESET}")
        echo -e "${C_INFO}#### FINE PROCESSO PER LXC ID $LXC_ID ####${C_RESET}"
        echo ""
        continue
    fi
    
    # --- 3.1 CREAZIONE DELLO SNAPSHOT PROXMOX ---
    SNAPSHOT_NAME="snap$(date +%Y%m%d%H%M%S)preupdate$LXC_ID"
    
    if "$DRY_RUN"; then
        echo -e "${C_WARNING}[DRY-RUN] Snapshot: Creazione simulata di $SNAPSHOT_NAME.${C_RESET}"
    else
        echo -e "${C_INFO}3.1 Creazione snapshot $SNAPSHOT_NAME...${C_RESET}"
        if ! /usr/sbin/pct snapshot "$LXC_ID" "$SNAPSHOT_NAME" --description "Snapshot prima aggiornamento Docker $LXC_ID"; then
            echo -e "${C_ERROR}ERRORE CRITICO: impossibile creare lo snapshot per LXC $LXC_ID.${C_RESET}"
            echo -e "${C_WARNING}Salto l'aggiornamento per motivi di sicurezza.${C_RESET}"
            REPORT+=("${C_ERROR}LXC $LXC_ID  ERRORE CRITICO (Snapshot fallito)${C_RESET}")
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
    # Rimuovi lo spazio/separatore finale inutile
    EXCLUDE_DOCKGE_PATHS=$(echo "$EXCLUDE_DOCKGE_PATHS" | xargs)

    # Costruisci il comando FIND (che ora accetta pi� radici e pi� esclusioni)
    SCAN_COMMAND="find $SCAN_ROOTS \
        -path \"*/proc\" -prune -o \
        -path \"*/sys\" -prune -o \
        -path \"*/dev\" -prune -o \
        -path \"*/tmp\" -prune -o \
        $EXCLUDE_DOCKGE_PATHS \
        -type f \\( -name \"docker-compose.yml\" -o -name \"docker-compose.yaml\" -o -name \"compose.yml\" -o -name \"compose.yaml\" \\) -print0 2>/dev/null \
        | xargs -0 dirname || true"
    
    # CORREZIONE DRY-RUN
    STACK_PATHS_OUTPUT=""
    if "$DRY_RUN"; then
        echo -e "   [DRY-RUN] PCT exec per la Scansione degli Stack (non eseguito):"
        echo "   $SCAN_COMMAND"
    else
        # Esecuzione live
        STACK_PATHS_OUTPUT=$(esegui_remoto "$LXC_ID" "$SCAN_COMMAND")
    fi

    if [ -n "$STACK_PATHS_OUTPUT" ]; then
        # Normalizza e pulisce gli spazi extra dall'output
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
        REPORT+=("${C_WARNING}LXC $LXC_ID  DRY-RUN COMPLETATO (Nessuna modifica applicata)${C_RESET}")
    elif [ "$TOTAL_STATUS" -eq 0 ]; then
        echo -e "${C_SUCCESS}AGGIORNAMENTO RIUSCITO per LXC $LXC_ID.${C_RESET}"
        echo -e "${C_INFO}Rimuovo lo snapshot temporaneo $SNAPSHOT_NAME...${C_RESET}"
        /usr/sbin/pct delsnapshot "$LXC_ID" "$SNAPSHOT_NAME"
        echo -e "${C_INFO}Pulizia completata.${C_RESET}"
        REPORT+=("${C_SUCCESS}LXC $LXC_ID  OK (Snapshot rimosso)${C_RESET}")
    else
        echo -e "${C_ERROR}ERRORE DURANTE L'AGGIORNAMENTO di LXC $LXC_ID! Codice Totale: $TOTAL_STATUS${C_RESET}"
        echo -e "${C_WARNING}Eseguo il ROLLBACK allo snapshot $SNAPSHOT_NAME...${C_RESET}"
        
        if ! /usr/sbin/pct rollback "$LXC_ID" "$SNAPSHOT_NAME"; then
            echo -e "${C_ERROR}ERRORE CRITICO: Fallito il rollback. Richiesta attenzione manuale su $LXC_ID!${C_RESET}"
            REPORT+=("${C_ERROR}LXC $LXC_ID  ERRORE FATALE (Rollback fallito!)${C_RESET}")
        else
            echo -e "${C_SUCCESS}Ripristino LXC $LXC_ID completato. Stato precedente ripristinato.${C_RESET}"
            echo -e "${C_INFO}Rimuovo lo snapshot temporaneo $SNAPSHOT_NAME...${C_RESET}"
            /usr/sbin/pct delsnapshot "$LXC_ID" "$SNAPSHOT_NAME"
            echo -e "${C_INFO}Pulizia completata.${C_RESET}"
            REPORT+=("${C_WARNING}LXC $LXC_ID  ROLLBACK ESEGUITO (Codice errore: $TOTAL_STATUS)${C_RESET}")
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

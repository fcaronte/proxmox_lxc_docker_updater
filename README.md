# ==============================================================================
# ๐ณ SCRIPT: update-lxc.sh
# ==============================================================================
#
# Questo script รจ progettato per automatizzare l'aggiornamento degli stack 
# Docker Compose all'interno dei container LXC su un host Proxmox.
#
# La sua caratteristica principale รจ la sicurezza: esegue automaticamente uno 
# snapshot Proxmox dell'LXC prima di qualsiasi aggiornamento e, in caso di 
# successo, elimina lo snapshot, altrimenti esegue un Rollback automatico.
#
# Sviluppato in collaborazione con l'assistente AI Gemini.
#
# ==============================================================================
# ๐ฎ๐น DOCUMENTAZIONE IN ITALIANO
# ==============================================================================
#
# # โจ Caratteristiche Principali
#
# * **Snapshot e Rollback Automatico:** Crea uno snapshot prima dell'aggiornamento e lo elimina (o esegue il rollback) in base all'esito.
# * **Scansione Docker Compose:** Identifica automaticamente gli stack Docker Compose nella directory configurata.
# * **Modalitร  Dry Run (`--dry-run`):** Permette di simulare l'intero processo senza eseguire alcuna modifica reale.
# * **Filtri Intelligenti:** Supporta ID LXC, nomi parziali, o la parola chiave `all` per tutti i container attivi.
#
# ------------------------------------------------------------------------------
# # โ๏ธ Configurazione Iniziale
#
# Prima di utilizzare lo script, assicurati che sia configurato per il tuo ambiente.
#
# Apri `update-lxc.sh` e modifica le seguenti variabili nella sezione `USER CONFIG`:
#
# | Variabile | Descrizione | Valore di Default |
# | :--- | :--- | :--- |
# | `SCAN_ROOT` | **Radice di Scansione:** La directory all'interno degli LXC dove lo script cercherร  i file `docker-compose.yml`. | `/root` |
# | `DOCKGE_PATH` | **Percorso Dockge:** Il percorso specifico dello stack Dockge. Viene aggiornato per primo ed escluso dalla scansione generale. | `/root/dockge_install/dockge` |
#
# ### Permessi di Esecuzione
#
# Assicurati che lo script abbia i permessi di esecuzione:
# ```bash
# chmod +x update-lxc.sh
# ```
#
# ------------------------------------------------------------------------------
# # ๐€ Utilizzo
#
# Lo script richiede uno o piรน identificatori LXC (ID o nome parziale) come argomento.
#
# ### 1. Modalitร  Dry Run (Simulazione)
#
# Usa l'opzione `--dry-run` per visualizzare esattamente cosa farebbe lo script:
#
# | Comando | Descrizione |
# | :--- | :--- |
# | `./update-lxc.sh --dry-run 8006` | Simula l'aggiornamento solo per l'LXC ID 8006. |
# | `./update-lxc.sh all --dry-run` | Simula l'aggiornamento per **tutti** gli LXC attivi. |
# | `./update-lxc.sh hom --dry-run` | Simula l'aggiornamento per tutti gli LXC il cui nome hostname contiene "hom" (e.g., Homarr). |
#
# ### 2. Aggiornamento Reale
#
# Per eseguire l'aggiornamento effettivo (con creazione dello snapshot):
#
# | Comando | Descrizione |
# | :--- | :--- |
# | `./update-lxc.sh 8006 8011` | Aggiorna solo gli LXC con ID 8006 e 8011. |
# | `./update-lxc.sh all` | **ATTENZIONE:** Aggiorna **tutti** gli LXC attivi che contengono Docker. |
# | `./update-lxc.sh immich` | Aggiorna LXC con hostname contenente "immich". |
#
# ------------------------------------------------------------------------------
# # ๐ก๏ธ Logica di Sicurezza e Rollback
#
# Ogni processo di aggiornamento segue questi passaggi garantiti:
#
# 1.  **Verifica Docker:** Salta l'LXC se Docker non รจ installato.
# 2.  **Snapshot:** Crea uno snapshot Proxmox temporaneo. Se fallisce, il processo si interrompe.
# 3.  **Aggiornamento Stacks:** Esegue `docker compose pull && docker compose up -d` prima su Dockge e poi su tutti gli altri stack rilevati.
# 4.  **Valutazione Finale:**
#     * โ… **Successo Totale:** Lo snapshot temporaneo viene **eliminato**.
#     * โ **Errore Rilevato:** Lo script esegue un **rollback immediato** allo snapshot iniziale e poi elimina lo snapshot.
#
# ==============================================================================
# ๐ฌ๐ง ENGLISH DOCUMENTATION
# ==============================================================================
#
# The `update-lxc.sh` script is designed to automate the update of **Docker Compose** # stacks inside **LXC** containers on a **Proxmox** host.
#
# Its primary feature is **security**: it automatically takes a **Proxmox snapshot** # of the LXC before any update. If the update is successful, it deletes the snapshot. 
# If the update fails, it executes an **Automatic Rollback** to the previously created 
# restore point.
#
# ------------------------------------------------------------------------------
# # โจ Key Features
#
# * **Automatic Snapshot and Rollback:** Creates a snapshot before the update and deletes it (or executes a rollback) based on the result.
# * **Docker Compose Scanning:** Automatically identifies Docker Compose stacks in the configured directory.
# * **Dry Run Mode (`--dry-run`):** Allows you to simulate the entire process without making any real changes.
# * **Intelligent Filtering:** Supports LXC IDs, partial names, or the keyword `all` for all active containers.
#
# ------------------------------------------------------------------------------
# # โ๏ธ Initial Configuration
#
# Before using the script, ensure it is configured for your environment.
#
# Open `update-lxc.sh` and modify the following sections in the **`USER CONFIG`** section:
#
# | Variable | Description | Default Value |
# | :--- | :--- | :--- |
# | `SCAN_ROOT` | **Scan Root:** The directory inside the LXC where the script will search for `docker-compose.yml` files. | `/root` |
# | `DOCKGE_PATH` | **Dockge Path:** The specific path for the Dockge stack. It is updated first and excluded from the general scan. | `/root/dockge_install/dockge` |
#
# ### Execution Permissions
#
# Ensure the script has execution permissions:
# ```bash
# chmod +x update-lxc.sh
# ```
#
# ------------------------------------------------------------------------------
# # ๐€ Usage
#
# The script requires one or more LXC identifiers (ID or partial name) as arguments.
#
# ### 1. Dry Run Mode (Simulation)
#
# Use the `--dry-run` option to see exactly what the script would do:
#
# | Command | Description |
# | :--- | :--- |
# | `./update-lxc.sh --dry-run 8006` | Simulates the update only for LXC ID 8006. |
# | `./update-lxc.sh all --dry-run` | Simulates the update for **all** active LXCs. |
# | `./update-lxc.sh hom --dry-run` | Simulates the update for all LXCs whose hostname contains "hom" (e.g., Homarr). |
#
# ### 2. Live Update
#
# To execute the actual update (with snapshot creation):
#
# | Command | Description |
# | :--- | :--- |
# | `./update-lxc.sh 8006 8011` | Updates only LXCs with ID 8006 and 8011. |
# | `./update-lxc.sh all` | **WARNING:** Updates **all** active LXCs that contain Docker. |
# | `./update-lxc.sh immich` | Updates LXC with hostname containing "immich". |
#
# ------------------------------------------------------------------------------
# # ๐ก๏ธ Security and Rollback Logic
#
# Each update process follows these guaranteed steps:
#
# 1.  **Docker Check:** Skips the LXC if Docker is not installed.
# 2.  **Snapshot:** Creates a temporary Proxmox snapshot. If it fails, the process stops.
# 3.  **Update Stacks:** Executes `docker compose pull && docker compose up -d` first on Dockge and then on all other detected stacks.
# 4.  **Final Assessment:**
#     * โ… **Total Success:** The temporary snapshot is **deleted**.
#     * โ **Error Detected:** The script executes an **immediate rollback** to the initial snapshot and then deletes the snapshot.
#
# ==============================================================================

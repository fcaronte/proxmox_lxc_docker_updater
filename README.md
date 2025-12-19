---

# SCRIPT update-lxc.sh (v1.7.0)

Script professionale e robusto per automatizzare l'aggiornamento degli stack **Docker Compose** all'interno dei container **LXC** su host **Proxmox**.

Sviluppato per garantire la massima sicurezza operativa attraverso l'integrazione nativa con le API di Proxmox.

---

## 🌟 Caratteristiche Principali

* **Sicurezza con Snapshot:** Crea automaticamente uno snapshot Proxmox prima di ogni modifica.
* **Rollback Automatico:** In caso di errore durante l'aggiornamento, lo script esegue il rollback istantaneo allo stato precedente.
* **Novità: Modalità No-Snap (`--no-snap`):** Permette aggiornamenti rapidi senza creare snapshot (utile per container non critici o con poco spazio disco).
* **Aggiornamento Selettivo:** Rileva quali container sono "Running" e aggiorna/riavvia solo quelli, lasciando i container fermi nel loro stato originale (ma con le immagini aggiornate).
* **Logica Digest (v1.6.5+):** Verifica l'Image ID reale di Docker per confermare se un aggiornamento è avvenuto effettivamente.
* **Multi-Path & Dockge:** Supporto nativo per installazioni multiple di Dockge e scansione di directory multiple (es. `/root` e `/opt`).

---

## ⚙️ Configurazione Iniziale

Modifica le variabili nella sezione **USER CONFIG** all'inizio dello script:

| Variabile | Descrizione | Default |
| --- | --- | --- |
| **SCAN_ROOTS** | Directory dove cercare file `compose.yml` (scansione profonda 2 livelli). | `/root /opt/stacks` |
| **DOCKGE_PATHS** | Percorsi specifici per Dockge. | `/root/dockge_install/dockge /opt/dockge` |
| **KEEP_LAST_SNAPSHOT** | Se `true`, mantiene l'ultimo snapshot di successo come backup. | `true` |

### Permessi

```bash
chmod +x update-lxc.sh

```

---

## 🚀 Utilizzo

### 1. Modalità Standard (Consigliata)

Esegue snapshot, aggiornamento e mantiene l'ultimo stato noto.

```bash
./update-lxc.sh 101          # Aggiorna LXC con ID 101
./update-lxc.sh immich       # Aggiorna LXC con nome contenente "immich"
./update-lxc.sh all          # Aggiorna TUTTI gli LXC attivi

```

### 2. Modalità Rapida (Senza Snapshot)

Aggiorna senza creare snapshot di sicurezza.

```bash
./update-lxc.sh all --no-snap

```

### 3. Simulazione e Manutenzione

| Comando | Descrizione |
| --- | --- |
| `./update-lxc.sh all --dry-run` | Visualizza le azioni senza eseguirle. |
| `./update-lxc.sh all clean` | Elimina manualmente TUTTI gli snapshot creati dallo script. |

---

## 🛠️ Logica Operativa

1. **Validazione:** Verifica se l'LXC è attivo e se Docker è installato.
2. **Protezione:** Crea uno snapshot Proxmox (es. `AUTO_UPDATE_SNAP_20251219...`).
3. **Aggiornamento Dockge:** Priorità alle istanze Dockge definite in `DOCKGE_PATHS`.
4. **Scansione Stack:** Cerca file `docker-compose.yml` o `compose.yaml` nelle radici configurate.
5. **Aggiornamento Intelligente:**
* `docker compose pull`
* Confronto Image ID (Digest).
* `docker compose up -d` solo per i servizi che erano già in esecuzione.


6. **Esito:**
* **Successo:** Snapshot mantenuto come backup (se configurato) + `docker image prune` per liberare spazio.
* **Fallimento:** Rollback automatico allo snapshot e notifica errore.


---

### 🌐 Esecuzione Diretta (One-Liner)

Se non vuoi scaricare e gestire localmente lo script, puoi eseguirlo direttamente dal repository GitHub. Questo metodo è utile per avere sempre l'ultima versione disponibile senza dover aggiornare manualmente il file.[!IMPORTANT]Sicurezza: Usa sempre i due trattini -- dopo il comando curl per separare gli argomenti passati allo script da quelli di bash

#### 1. Aggiornamento completo con snapshot (Tutti gli LXC)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fcaronte/proxmox_lxc_docker_updater/main/update-lxc.sh)" -- all

```

#### 2. Aggiornamento rapido SENZA snapshot (Tutti gli LXC)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fcaronte/proxmox_lxc_docker_updater/main/update-lxc.sh)" -- all --no-snap

```

#### 3. Pulizia totale degli snapshot obsoleti

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fcaronte/proxmox_lxc_docker_updater/main/update-lxc.sh)" -- clean all

```

#### 4. Simulazione (Dry-run) per un ID specifico

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fcaronte/proxmox_lxc_docker_updater/main/update-lxc.sh)" -- 101 --dry-run

```

---

## 🇬🇧 English Summary

`update-lxc.sh` is a maintenance script for Proxmox LXC containers running Docker. It ensures safe updates by leveraging Proxmox snapshots.

**Key Flags:**

* `--no-snap`: Skip snapshot creation for faster updates.
* `--dry-run`: Simulation mode.
* `clean`: Remove all script-generated snapshots.

**Selective Update Logic:** It only restarts services that were running before the update, keeping your environment's state consistent.


---

### 🌐 Direct Execution (One-Liner)

You can run the script directly from the GitHub repository without downloading it. This ensures you are always using the latest version (v1.7.0).

> [!IMPORTANT]
> **Security:** Always use the double dash `--` after the curl command to separate the script arguments from the bash options.

#### 1. Full Update with Snapshot (All LXCs)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fcaronte/proxmox_lxc_docker_updater/main/update-lxc.sh)" -- all

```

#### 2. Fast Update WITHOUT Snapshot (All LXCs)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fcaronte/proxmox_lxc_docker_updater/main/update-lxc.sh)" -- all --no-snap

```

#### 3. Total Cleanup of Obsolete Snapshots

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fcaronte/proxmox_lxc_docker_updater/main/update-lxc.sh)" -- clean all

```

#### 4. Simulation (Dry-run) for a Specific ID

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fcaronte/proxmox_lxc_docker_updater/main/update-lxc.sh)" -- 101 --dry-run

```

---

### Command Breakdown

* **`curl -fsSL`**: Downloads the script content silently.
* **`bash -c "$(..." )"`**: Executes the downloaded content directly in memory.
* **`--`**: Tells Bash that everything following it is an argument for the script itself.
* **`all`, `clean`, `--no-snap**`: The script parameters to define the execution mode.


## 📝 Licenza e Note

Sviluppato con **Gemini AI**. Usare con cautela. L'opzione `all` è potente: si consiglia sempre un `--dry-run` preventivo.

---

**Ti serve altro per completare la tua repository GitHub, come ad esempio un file `.gitignore` o delle istruzioni per l'automazione tramite Cron?**

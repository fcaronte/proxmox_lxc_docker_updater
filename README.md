## 🌍 Language / Lingua
* [🇮🇹 Leggi in Italiano](#-proxmox-lxc-docker-updater-italiano)
* [🇬🇧 Read in English](#-proxmox-lxc-docker-updater-english)

---

# 🇮🇹 Proxmox LXC Docker Updater (Italiano)
```markdown
# 🚀 Proxmox LXC Docker Updater (v1.8.9+)

[![Bash Script](https://img.shields.io/badge/language-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![Proxmox](https://img.shields.io/badge/Platform-Proxmox-E57020.svg)](https://www.proxmox.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Script professionale per l'aggiornamento automatizzato di stack **Docker Compose** all'interno di container **LXC Proxmox**. Gestisce snapshot, rollback e integrazione nativa con **Home Assistant**.

---

## 🌟 Caratteristiche Principali

* **Deep Tag Resolution**: Confronta l'ID dell'immagine in esecuzione con l'ID reale sul disco dopo il pull. Risolve il problema dei falsi aggiornamenti con tag `:latest`.
* **Smart State Restoration**: Rispetta lo stato dei tuoi servizi. Se un container era spento prima dell'aggiornamento, verrà riportato allo stato *stopped* automaticamente.
* **Integrazione Home Assistant (HA)**: Modalità `ha` dedicata che silenzia l'output SSH (evitando timeout) e invia una notifica push con il report finale.
* **Sicurezza Integrata**: 
    * Snapshot automatico del LXC prima di ogni operazione.
    * **Rollback automatico** con riavvio del LXC in caso di errore durante il pull o l'avvio.
    * Report intelligente: se un LXC fallisce, i successi parziali vengono segnalati come annullati nel log.
* **Auto-Cleanup**: Esegue `docker image prune` alla fine di ogni aggiornamento riuscito per risparmiare spazio.

---

## 🔑 Requisiti per Home Assistant

Per controllare gli aggiornamenti dall'App di HA, configura Proxmox come segue:

1.  **Accesso SSH senza password**: La chiave pubblica di HA deve essere presente in `/root/.ssh/authorized_keys` su Proxmox.
2.  **File dei Segreti**: Crea il file `/root/ha_secret.conf` su Proxmox:
    ```bash
    HA_URL="[https://tuo-ha.duckdns.org/api/services/notify/mobile_app_tuo_smartphone](https://tuo-ha.duckdns.org/api/services/notify/mobile_app_tuo_smartphone)"
    HA_TOKEN="Bearer TUO_TOKEN_LONG_LIVED"
    ```

---

## 🤖 Configurazione su Home Assistant

### 1. Shell Command
Aggiungi al tuo `configuration.yaml`:
```yaml
shell_command:
  aggiorna_lxc: 'ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no root@IP_PROXMOX "bash /root/update-lxc.sh {{ lxc_id }} ha"'

```

### 2. Script (Esempio)

Crea uno script nell'interfaccia di HA per richiamare il comando:

```yaml
alias: Aggiorna Immich
sequence:
  - action: shell_command.aggiorna_lxc
    data:
      lxc_id: "immich" # Può essere l'ID numerico o il nome del LXC

```

---

## 🚀 Esecuzione Diretta (CLI)

Puoi eseguire lo script direttamente dal terminale di Proxmox usando i seguenti comandi:

| Comando | Descrizione |
| --- | --- |
| `update-lxc.sh all` | Aggiorna tutti i LXC rilevati. |
| `update-lxc.sh 100` | Aggiorna solo il LXC con ID 100. |
| `update-lxc.sh all ha` | Aggiorna tutto e invia notifica push a HA. |
| `update-lxc.sh all --dry-run` | Simula l'operazione senza modificare nulla. |
| `update-lxc.sh all --no-snap` | Esegue l'aggiornamento senza creare snapshot. |

### One-Liner per l'aggiornamento rapido:

```bash
bash -c "$(curl -fsSL [https://raw.githubusercontent.com/fcaronte/proxmox_lxc_docker_updater/main/update-lxc.sh](https://raw.githubusercontent.com/fcaronte/proxmox_lxc_docker_updater/main/update-lxc.sh))" -- all ha

```

---

## 📋 Note Tecniche

Lo script scansiona automaticamente le cartelle configurate in `SCAN_ROOTS` (default: `/root` e `/opt/stacks`) alla ricerca di file `docker-compose.yml` o `compose.yaml`.

### Gestione Rollback

Se lo script rileva un errore durante il `docker compose up`, eseguirà immediatamente:

1. `pct rollback` all'istante precedente l'inizio.
2. `pct start` per assicurare la continuità del servizio.
3. Notifica HA con prefisso `❌` per gli stack annullati.

---

## 📝 Licenza

Sviluppato con il supporto di **Gemini AI**.
Distribuito sotto licenza MIT. Usare con cautela: si consiglia sempre un `--dry-run` prima di aggiornamenti massivi.


# 🇬🇧 Proxmox LXC Docker Updater (English)


```markdown
# 🚀 Proxmox LXC Docker Updater (v1.8.9+)

[![Bash Script](https://img.shields.io/badge/language-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![Proxmox](https://img.shields.io/badge/Platform-Proxmox-E57020.svg)](https://www.proxmox.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A professional script for automated updates of **Docker Compose** stacks running inside **Proxmox LXC** containers. It features snapshot management, automatic rollback, and native **Home Assistant** integration.

---

## 🌟 Key Features

* **Deep Tag Resolution**: Compares the running image ID with the actual on-disk ID after pull. Solves the "fake update" issue with `:latest` tags.
* **Smart State Restoration**: Respects your service states. If a container was stopped before the update, it will be automatically stopped again after the update is completed.
* **Home Assistant (HA) Integration**: Dedicated `ha` mode that silences SSH output (preventing timeouts) and sends a push notification with the final report.
* **Safety First**: 
    * Automatic LXC snapshot before any operation.
    * **Automatic Rollback**: Reverts to the previous state and restarts the LXC if an error occurs during pull or startup.
    * Intelligent Reporting: If an LXC update fails, any partial successes are marked as "Reverted" in the logs.
* **Auto-Cleanup**: Runs `docker image prune` after every successful update to save disk space.

---

## 🔑 Home Assistant Prerequisites

To trigger updates from the HA App, configure Proxmox as follows:

1.  **Passwordless SSH Access**: HA's public key must be added to `/root/.ssh/authorized_keys` on your Proxmox host.
2.  **Secrets File**: Create the file `/root/ha_secret.conf` on Proxmox:
    ```bash
    HA_URL="[https://your-ha.duckdns.org/api/services/notify/mobile_app_your_smartphone](https://your-ha.duckdns.org/api/services/notify/mobile_app_your_smartphone)"
    HA_TOKEN="Bearer YOUR_LONG_LIVED_TOKEN"
    ```

---

## 🤖 Home Assistant Setup

### 1. Shell Command
Add this to your `configuration.yaml`:
```yaml
shell_command:
  update_lxc: 'ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no root@PROXMOX_IP "bash /root/update-lxc.sh {{ lxc_id }} ha"'

```

### 2. Script (Example)

Create a script in the HA UI to trigger the command:

```yaml
alias: Update Immich
sequence:
  - action: shell_command.update_lxc
    data:
      lxc_id: "immich" # Can be the numerical ID or the LXC hostname

```

---

## 🚀 CLI Execution

You can run the script directly from the Proxmox terminal:

| Command | Description |
| --- | --- |
| `update-lxc.sh all` | Updates all detected LXCs. |
| `update-lxc.sh 100` | Updates only the LXC with ID 100. |
| `update-lxc.sh all ha` | Updates all and sends a push notification to HA. |
| `update-lxc.sh all --dry-run` | Simulates the operation without making changes. |
| `update-lxc.sh all --no-snap` | Runs the update without creating snapshots. |

### Quick One-Liner:

```bash
bash -c "$(curl -fsSL [https://raw.githubusercontent.com/fcaronte/proxmox_lxc_docker_updater/main/update-lxc.sh](https://raw.githubusercontent.com/fcaronte/proxmox_lxc_docker_updater/main/update-lxc.sh))" -- all ha

```

---

## 📋 Technical Notes

The script automatically scans paths configured in `SCAN_ROOTS` (default: `/root` and `/opt/stacks`) for `docker-compose.yml` or `compose.yaml` files.

### Rollback Management

If the script detects an error during `docker compose up`, it immediately executes:

1. `pct rollback` to the state before the update started.
2. `pct start` to ensure service continuity.
3. HA Notification with a `❌` prefix for the reverted stacks.

---

## 📝 License

Developed with support from **Gemini AI**.
Distributed under the MIT License. Use with caution: always perform a `--dry-run` before mass updates.

```

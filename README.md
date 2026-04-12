
-----

# 🌍 Language / Lingua

  * [🇮🇹 Leggi in Italiano](https://www.google.com/search?q=%23-proxmox-lxc-docker-updater-italiano)
  * [🇬🇧 Read in English](https://www.google.com/search?q=%23-proxmox-lxc-docker-updater-english)

-----

# 🇮🇹 Proxmox LXC Docker Updater (Italiano)

````markdown
# 🚀 Proxmox LXC Docker Updater (v1.9.0+)

[![Bash Script](https://img.shields.io/badge/language-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![Proxmox](https://img.shields.io/badge/Platform-Proxmox-E57020.svg)](https://www.proxmox.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Script avanzato per l'aggiornamento automatizzato di container Docker all'interno di LXC Proxmox. Questa versione introduce un'interfaccia grafica interattiva e una gestione intelligente della pulizia degli snapshot.

---

## 🌟 Novità Versione 1.9.x

* **Interfaccia Grafica (GUI)**: Se avviato senza argomenti, lo script apre un menu interattivo (whiptail) per selezionare i container e le opzioni di aggiornamento.
* **Supporto Nativo Dockge**: Gestione prioritaria per gli stack gestiti tramite Dockge (rileva automaticamente i percorsi `/opt/dockge`).
* **Modalità Clean**: Nuova opzione per eliminare TUTTI gli snapshot creati dallo script dopo un aggiornamento riuscito, mantenendo il sistema Proxmox pulito.
* **Deep Tag Resolution**: Confronta gli ID reali delle immagini per evitare riavvii inutili se l'immagine non è cambiata.
* **Smart State Restoration**: Mantiene lo stato originale dei servizi (se un container era spento, rimarrà spento dopo l'aggiornamento).

---

## 🚀 Modalità di Esecuzione

### 1. Modalità Interattiva (GUI)
Semplicemente esegui lo script senza parametri:
```bash
bash update-lxc.sh
````

Si aprirà un menu dove potrai scegliere quali LXC aggiornare e quali flag attivare (Clean, No-Snap, Dry-Run, HA).

### 2\. Modalità CLI (Terminale)

| Comando | Descrizione |
| --- | --- |
| `update-lxc.sh all` | Aggiorna tutti i LXC rilevati. |
| `update-lxc.sh 100 clean` | Aggiorna il LXC 100 e rimuove i suoi snapshot AUTO\_UPDATE. |
| `update-lxc.sh all ha` | Esegue tutto e invia il report push a Home Assistant. |
| `update-lxc.sh --dry-run` | Simula l'operazione senza applicare modifiche. |
| `update-lxc.sh --no-snap` | Aggiorna senza creare snapshot di sicurezza. |

-----

## 🔑 Integrazione Home Assistant

1.  **File Segreti**: Crea `/root/ha_secret.conf`:
    ```bash
    HA_URL="[https://tuo-ha.duckdns.org/api/services/notify/mobile_app_tuo_smartphone](https://tuo-ha.duckdns.org/api/services/notify/mobile_app_tuo_smartphone)"
    HA_TOKEN="Bearer TUO_TOKEN_LONG_LIVED"
    ```
2.  **Comando Shell**: In `configuration.yaml`:
    ```yaml
    shell_command:
      aggiorna_lxc: 'ssh -o StrictHostKeyChecking=no root@IP_PROXMOX "bash /root/update-lxc.sh {{ lxc_id }} ha"'
    ```

-----

## 📋 Note Tecniche e Sicurezza

  * **Snapshot**: Lo script crea uno snapshot chiamato `AUTO_UPDATE_SNAP_...`.
  * **Rollback**: In caso di errore durante il `docker compose up`, lo script esegue automaticamente il rollback allo stato precedente.
  * **Pruning**: Al termine di ogni successo, viene eseguito `docker image prune -af` per liberare spazio nel LXC.

-----

## 📝 Licenza

Sviluppato con il supporto di **Gemini AI**. Licenza MIT.

````

---

# 🇬🇧 Proxmox LXC Docker Updater (English)

```markdown
# 🚀 Proxmox LXC Docker Updater (v1.9.0+)

[![Bash Script](https://img.shields.io/badge/language-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![Proxmox](https://img.shields.io/badge/Platform-Proxmox-E57020.svg)](https://www.proxmox.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Advanced script for automated Docker container updates inside Proxmox LXCs. This version introduces an interactive GUI and intelligent snapshot cleanup management.

---

## 🌟 Version 1.9.x Highlights

* **Interactive GUI**: Launching the script without arguments opens a whiptail menu to select containers and update options.
* **Dockge Native Support**: Priority management for stacks handled via Dockge (automatically detects `/opt/dockge` paths).
* **Clean Mode**: New option to delete ALL snapshots created by the script after a successful update, keeping your Proxmox storage tidy.
* **Deep Tag Resolution**: Compares actual image IDs to prevent unnecessary restarts if the image hasn't changed.
* **Smart State Restoration**: Respects original service states (stopped containers stay stopped after update).

---

## 🚀 Execution Modes

### 1. Interactive Mode (GUI)
Simply run the script with no parameters:
```bash
bash update-lxc.sh
````

A menu will appear allowing you to pick LXCs and toggle flags (Clean, No-Snap, Dry-Run, HA).

### 2\. CLI Mode (Terminal)

| Command | Description |
| --- | --- |
| `update-lxc.sh all` | Updates all detected LXCs. |
| `update-lxc.sh 100 clean` | Updates LXC 100 and removes its AUTO\_UPDATE snapshots. |
| `update-lxc.sh all ha` | Runs all and sends a push report to Home Assistant. |
| `update-lxc.sh --dry-run` | Simulates the operation without making changes. |
| `update-lxc.sh --no-snap` | Runs the update without creating security snapshots. |

-----

## 🔑 Home Assistant Integration

1.  **Secrets File**: Create `/root/ha_secret.conf`:
    ```bash
    HA_URL="[https://your-ha.duckdns.org/api/services/notify/mobile_app_your_phone](https://your-ha.duckdns.org/api/services/notify/mobile_app_your_phone)"
    HA_TOKEN="Bearer YOUR_LONG_LIVED_TOKEN"
    ```
2.  **Shell Command**: In `configuration.yaml`:
    ```yaml
    shell_command:
      update_lxc: 'ssh -o StrictHostKeyChecking=no root@PROXMOX_IP "bash /root/update-lxc.sh {{ lxc_id }} ha"'
    ```

-----

## 📋 Technical Notes & Safety

  * **Snapshots**: The script creates a snapshot named `AUTO_UPDATE_SNAP_...`.
  * **Rollback**: If an error is detected during `docker compose up`, it automatically performs a rollback to the previous state.
  * **Pruning**: Runs `docker image prune -af` inside the LXC after every success to reclaim disk space.

-----

## 📝 License

Developed with **Gemini AI** support. MIT License.

```
```

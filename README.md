---

# 🌍 Language / Lingua

* [🇮🇹 Leggi in Italiano](https://www.google.com/search?q=%23-proxmox-lxc-docker-updater-italiano)
* [🇬🇧 Read in English](https://www.google.com/search?q=%23-proxmox-lxc-docker-updater-english)

---

# 🇮🇹 Proxmox LXC Docker Updater (Italiano)

```markdown
# 🚀 Proxmox LXC Docker Updater (v2.1.0)

[![Bash Script](https://img.shields.io/badge/language-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![Proxmox](https://img.shields.io/badge/Platform-Proxmox-E57020.svg)](https://www.proxmox.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Script avanzato per l'aggiornamento automatizzato di container Docker all'interno di LXC Proxmox. La versione 2.1.0 introduce la gestione avanzata in **background persistente** (protetta da disconnessioni SSH/Tailscale) e la **prioritizzazione intelligente degli stack critici** (es. WireGuard, Tailscale, Termix, Nginx Proxy Manager), che vengono aggiornati rigorosamente per ultimi per evitare interruzioni premature della sessione.

---

## 🌟 Novità Versione 2.1.x

- **Esecuzione in Background (`BACKGROUND`)**: Dall'interfaccia interattiva è possibile inviare l'aggiornamento in background tramite `setsid`, permettendo al processo di continuare in autonomia anche se la VPN o la connessione SSH cadono.
- **Stack Critici per Ultimi**: Rilevamento automatico e ordinamento dei container e dei servizi critici (es. Tailscale, WireGuard, Termix) per essere eseguiti alla fine, con tentativi di verifica automatica (`polling`) della ripartenza.
- **Interfaccia Grafica (GUI) Dinamica**: Menu interattivo tramite `whiptail` con calcolo automatico e sicuro delle dimensioni dello schermo del terminale.
- **Supporto Nativo Dockge & Deep Tag Resolution**: Gestione prioritaria dei percorsi Dockge e confronto avanzato degli ID delle immagini per evitare riavvii superflui.
- **Modalità Clean & Smart Rollback**: Pulizia avanzata degli snapshot temporanei e gestione sicura del rollback in caso di errori.

---

## 🚀 Modalità di Esecuzione

### 1. Modalità Interattiva (GUI)
Esegui semplicemente lo script senza parametri:
```bash
bash update-lxc.sh

```

Il menu interattivo permetterà di:

1. Selezionare i container desiderati o l'opzione `BACKGROUND` / `ALL`.
2. Scegliere le flag desiderate (`clean`, `nosnap`, `dryrun`, `ha`).

### 2. Modalità CLI (Terminale)

| Comando | Descrizione |
| --- | --- |
| `update-lxc.sh all` | Aggiorna tutti i LXC rilevati (ordinando prima i normali e per ultimi quelli critici). |
| `update-lxc.sh -i 100 clean` | Aggiorna il LXC 100 e pulisce i vecchi snapshot. |
| `update-lxc.sh all ha` | Esegue l'aggiornamento e invia il report push a Home Assistant. |
| `update-lxc.sh --dry-run` | Simula l'operazione senza applicare modifiche. |
| `update-lxc.sh --no-snap` | Salta la creazione degli snapshot di sicurezza. |

---

## 🔑 Integrazione Home Assistant

1. **File Segreti**: Crea `/root/ha_secret.conf`:
```bash
HA_URL="[https://tuo-ha.duckdns.org/api/services/notify/mobile_app_tuo_smartphone](https://tuo-ha.duckdns.org/api/services/notify/mobile_app_tuo_smartphone)"
HA_TOKEN="Bearer TUO_TOKEN_LONG_LIVED"

```


2. **Comando Shell**: In `configuration.yaml`:
```yaml
shell_command:
  aggiorna_lxc: 'ssh -o StrictHostKeyChecking=no root@IP_PROXMOX "bash /root/update-lxc.sh {{ lxc_id }} ha"'

```



---

## 📋 Note Tecniche e Sicurezza

* **Protezione VPN/SSH**: L'esecuzione in background disaccoppia il processo (`setsid`), ideale per aggiornare container di networking critici (WireGuard/Tailscale) senza rischiare di troncare il comando a metà.
* **Snapshot e Rollback**: Creazione automatica di snapshot `AUTO_UPDATE_SNAP_...` con logiche di rollback dedicate per gli stack standard.
* **Pruning**: Esecuzione automatica di `docker image prune -af` al termine di ogni LXC aggiornato con successo per recuperare spazio disco.

---

## 📝 Licenza

Sviluppato con il supporto di **Gemini AI**. Licenza MIT.

```

---

# 🇬🇧 Proxmox LXC Docker Updater (English)

```markdown
# 🚀 Proxmox LXC Docker Updater (v2.1.0)

[![Bash Script](https://img.shields.io/badge/language-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![Proxmox](https://img.shields.io/badge/Platform-Proxmox-E57020.svg)](https://www.proxmox.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Advanced script for automated Docker container updates inside Proxmox LXCs. Version 2.1.0 introduces **persistent background execution** (safe against SSH/Tailscale drops) and **smart critical stack prioritization** (e.g., WireGuard, Tailscale, Termix, Nginx Proxy Manager), which are updated strictly last to prevent premature session interruptions.

---

## 🌟 Version 2.1.x Highlights

- **Background Execution (`BACKGROUND`)**: Easily send the update process to the background via the interactive menu (`setsid`), allowing tasks to safely finish even if your VPN or SSH connection disconnects.
- **Critical Stacks Last**: Automatic detection and sorting of critical containers/services (e.g., Tailscale, WireGuard) to run at the very end, complete with automated restart polling checks.
- **Dynamic Interactive GUI**: Whiptail-powered interface with automatic, safe terminal screen dimension calculations.
- **Dockge Native Support & Deep Tag Resolution**: Priority management for Dockge paths and deep image ID checks to prevent redundant restarts.
- **Clean Mode & Smart Rollback**: Advanced temporary snapshot purging and safe rollback logic in case of errors.

---

## 🚀 Execution Modes

### 1. Interactive Mode (GUI)
Simply run the script with no parameters:
```bash
bash update-lxc.sh

```

The interactive menu will let you:

1. Select target LXCs, toggle `BACKGROUND` execution, or choose `ALL`.
2. Pick desired flags (`clean`, `nosnap`, `dryrun`, `ha`).

### 2. CLI Mode (Terminal)

| Command | Description |
| --- | --- |
| `update-lxc.sh all` | Updates all detected LXCs (sorting normal stacks first, critical ones last). |
| `update-lxc.sh -i 100 clean` | Updates LXC 100 and cleans up old snapshots. |
| `update-lxc.sh all ha` | Runs updates and dispatches a push notification report to Home Assistant. |
| `update-lxc.sh --dry-run` | Simulates the operation without making changes. |
| `update-lxc.sh --no-snap` | Runs updates without creating safety snapshots. |

---

## 🔑 Home Assistant Integration

1. **Secrets File**: Create `/root/ha_secret.conf`:
```bash
HA_URL="[https://your-ha.duckdns.org/api/services/notify/mobile_app_your_phone](https://your-ha.duckdns.org/api/services/notify/mobile_app_your_phone)"
HA_TOKEN="Bearer YOUR_LONG_LIVED_TOKEN"

```


2. **Shell Command**: In `configuration.yaml`:
```yaml
shell_command:
  update_lxc: 'ssh -o StrictHostKeyChecking=no root@PROXMOX_IP "bash /root/update-lxc.sh {{ lxc_id }} ha"'

```



---

## 📋 Technical Notes & Safety

* **VPN/SSH Drop Protection**: Background mode detaches the process (`setsid`), making it ideal for updating critical networking containers (WireGuard/Tailscale) without risking command termination midway.
* **Snapshots & Rollbacks**: Automatic creation of `AUTO_UPDATE_SNAP_...` snapshots with dedicated rollback behaviors for standard stacks.
* **Pruning**: Automatically executes `docker image prune -af` inside successfully updated LXCs to reclaim disk space.

---

## 📝 License

Developed with **Gemini AI** support. MIT License.

```

```

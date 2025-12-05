# SCRIPT update-lxc.sh

Script robusto per automatizzare l'aggiornamento degli stack **Docker Compose** all'interno dei container **LXC** su un host **Proxmox**.

La caratteristica principale è la **sicurezza**: viene creato automaticamente uno **snapshot Proxmox** prima di ogni aggiornamento.

* Di default mantiene l'ultimo snapshot di successo per facilitare rollback manuali.
* Se l'aggiornamento fallisce -> viene eseguito un **rollback automatico** e lo snapshot viene eliminato.
* Aggiornamento selettivo: rileva automaticamente i container Docker fermi e li aggiorna senza avviarli.

Sviluppato in collaborazione con l'assistente AI Gemini.

---

## NOVITA'

* **Keep Last Snapshot:** Per default (`KEEP_LAST_SNAPSHOT=true`) mantiene l'ultimo snapshot di successo.
* **Aggiornamento Selettivo:** Rileva i servizi attivi e aggiorna solo quelli, mantenendo i container fermi nello stato fermo.
* **Supporto Multi-Path:** Ora supporta più percorsi per scansione Docker e installazioni Dockge.
* **Logica Ottimizzata:** Pulizia automatica dei vecchi snapshot gestiti dallo script.
* **Modalità Pulizia (`clean`):** Nuova opzione per eliminare manualmente gli snapshot di sicurezza obsoleti.
* **Correzioni Bug:** Migliorata gestione caratteri speciali e stabilità generale.

---

## Configurazione Iniziale ⚙️

Prima di utilizzare lo script, modifica le variabili nella sezione **USER CONFIG**:

| Variabile | Descrizione | Default |
| :--- | :--- | :--- |
| **SCAN\_ROOTS** | Directory nell'LXC dove cercare gli stack compose (supporta multipli, separati da spazio) | `/root /opt/stacks` |
| **DOCKGE\_PATHS** | Percorsi delle installazioni di Dockge (supporta multipli, separati da spazio) | `/root/dockge_install/dockge /opt/dockge` |
| **KEEP\_LAST\_SNAPSHOT** | Se `true`, mantiene l'ultimo snapshot di successo. | `true` |

### Permessi di esecuzione
```bash
chmod +x update-lxc.sh
````

-----

## Utilizzo 🚀

Lo script richiede uno o più identificatori LXC (ID o nome parziale) come argomento.

### 1\. Modalità Dry Run (Simulazione)

Visualizza cosa accadrebbe senza eseguire modifiche reali:

| Comando | Descrizione |
| :--- | :--- |
| `./update-lxc.sh --dry-run 8006` | Simula aggiornamento per LXC ID 8006. |
| `./update-lxc.sh all --dry-run` | Simula aggiornamento per tutti gli LXC attivi. |
| `./update-lxc.sh hom --dry-run` | Simula aggiornamento per LXC con hostname contenente "hom" (es. Homarr). |

### 2\. Aggiornamento Reale

Esegue l'aggiornamento con snapshot:

| Comando | Descrizione |
| :--- | :--- |
| `./update-lxc.sh 8006 8011` | Aggiorna solo gli LXC con ID 8006 e 8011. |
| `./update-lxc.sh all` | **ATTENZIONE:** Aggiorna tutti gli LXC attivi con Docker. |
| `./update-lxc.sh immich` | Aggiorna LXC con hostname contenente "immich". |

### 3\. Modalità Pulizia Snapshot 🗑️ (NOVITÀ)

Elimina tutti gli snapshot creati dallo script (`AUTO_UPDATE_SNAP_`) per gli LXC specificati, liberando spazio.

| Comando | Descrizione |
| :--- | :--- |
| `./update-lxc.sh all clean` | Pulisce gli snapshot per tutti gli LXC attivi. |
| `./update-lxc.sh clean 8006 imm` | Pulisce gli snapshot solo per LXC 8006 e quelli con nome contenente "imm". |

-----

## Esecuzione Diretta (Opzionale) 🌐

È possibile eseguire l'ultima versione dello script direttamente dal repository GitHub senza doverlo scaricare e rendere eseguibile.

> ⚠️ **ATTENZIONE:** Usare cautela quando si eseguono script scaricati direttamente dalla rete. Sostituisci `[URL_GREZZO_SCRIPT]` con l'URL raw del tuo script.

| Comando | Descrizione |
| :--- | :--- |
| `bash -c "$(curl -fsSL https://raw.githubusercontent.com/fcaronte/proxmox_lxc_docker_updater/main/update-lxc.sh)" -- all` | Scarica ed esegue l'ultima versione su tutti gli LXC attivi. |
| `bash -c "$(curl -fsSL https://raw.githubusercontent.com/fcaronte/proxmox_lxc_docker_updater/main/update-lxc.sh)" -- clean all` | Scarica ed esegue la pulizia degli snapshot su tutti gli LXC. |

-----

## Logica di Aggiornamento Selettivo

La nuova versione implementa un aggiornamento intelligente:

1.  **Rilevamento stato:** Identifica quali servizi erano attivi prima dell'aggiornamento.
2.  **Pull immagini:** Scarica tutte le nuove immagini disponibili.
3.  **Avvio selettivo:** Riavvia solo i servizi che erano già in esecuzione.
4.  **Mantenimento stato:** I container fermi rimangono fermi dopo l'aggiornamento.

**Esempio:** Se hai un stack con 5 servizi ma solo 3 attivi, dopo l'aggiornamento:

  * I 3 servizi attivi vengono aggiornati e riavviati.
  * I 2 servizi fermi vengono aggiornati ma rimangono fermi.

-----

## Logica di Sicurezza e Snapshot

Ogni aggiornamento segue questi passaggi:

1.  Verifica Docker → se non installato, l'LXC viene saltato.
2.  Pulizia snapshot vecchi → rimuove automaticamente i vecchi snapshot creati dallo script.
3.  Creazione nuovo snapshot → se fallisce, il processo si interrompe.
4.  Aggiornamento stack → in ordine:
      * Prima tutti gli stack Dockge configurati.
      * Poi tutti gli altri stack rilevati (esclusi Dockge).
5.  **Gestione esito:**
      * Successo totale → snapshot mantenuto (se `KEEP_LAST_SNAPSHOT=true`).
      * Errore rilevato → **rollback immediato** + eliminazione snapshot fallito.

-----

## Esempio di Output

```
#### AVVIO PROCESSO PER LXC ID 8006 ####
3.1.1 Pulizia vecchi snapshot con prefisso 'AUTO_UPDATE_SNAP' per LXC 8006...
3.1.2 Creazione snapshot AUTO_UPDATE_SNAP_20231201120000_8006...
    -> Aggiornamento selettivo Dockge (/opt/dockge)...
    -> Avvio/Aggiornamento solo dei servizi attivi: (web api)...
    -> Aggiornamento selettivo Immich in /opt/immich...
    -> Nessun servizio attivo trovato. Immagini aggiornate, stato mantenuto (stoppato).
AGGIORNAMENTO RIUSCITO per LXC 8006.
Configurazione KEEP_LAST_SNAPSHOT=true: lo snapshot AUTO_UPDATE_SNAP_... viene MANTENUTO.
```

-----

## English Documentation 🇬🇧

The `update-lxc.sh` script automates updating Docker Compose stacks inside LXC containers on a Proxmox host.

### Key Features

  * Automatic Snapshot with Keep Last Option.
  * **Selective Update:** Updates images but only restarts running containers.
  * **Clean Mode:** Manual cleanup of old snapshots.
  * Docker Compose scanning with multiple paths.
  * Dry Run mode (`--dry-run`).

### Usage

  * Dry Run: `./update-lxc.sh --dry-run 8006`
  * Live Update: `./update-lxc.sh 8006 8011`
  * **Cleanup:** `./update-lxc.sh all clean`

### Security and Snapshot Logic

1.  Docker check.
2.  Old snapshot cleanup.
3.  New snapshot creation.
4.  Update stacks (Dockge first, then others).
5.  Success → snapshot kept (if configured).
    Failure → rollback + snapshot deletion.

-----

## Licenza

Questo script è distribuito per uso personale e amministrativo.
Usalo con cautela: l'opzione `"all"` può modificare tutti i container attivi.
Si consiglia sempre di eseguire prima un `--dry-run` per verificare cosa verrà modificato.

**Nota:** La funzionalità "Keep Last Snapshot" può occupare spazio su disco. Monitorare periodicamente gli snapshot Proxmox.

```
```

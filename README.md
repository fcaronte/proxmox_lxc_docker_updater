
# SCRIPT update-lxc.sh

Script per automatizzare l'aggiornamento degli stack **Docker Compose** all'interno dei container **LXC** su un host **Proxmox**.  
La caratteristica principale è la **sicurezza**: viene creato automaticamente uno **snapshot Proxmox** prima di ogni aggiornamento.  
- Se l'aggiornamento ha successo -> lo snapshot viene eliminato.  
- Se l'aggiornamento fallisce -> viene eseguito un **rollback automatico**.  

Sviluppato in collaborazione con l'assistente AI Gemini.

---

## Caratteristiche Principali

- **Snapshot e Rollback Automatico**  
- **Scansione Docker Compose** nelle directory configurate  
- **Modalita Dry Run (--dry-run)** per simulazioni senza modifiche reali  
- **Filtri intelligenti**: supporta ID LXC, nomi parziali o la keyword "all"  

---

## Configurazione Iniziale

Prima di utilizzare lo script, modifica le variabili nella sezione **USER CONFIG**:

| Variabile     | Descrizione                                                                 | Default |
|---------------|-----------------------------------------------------------------------------|---------|
| SCAN_ROOT     | Radice di scansione: directory dove cercare i file docker-compose.yml       | /root /opt/stacks  |
| DOCKGE_PATH   | Percorsi dello stack Dockge (aggiornato per primo ed escluso dalla scansione) | /root/dockge_install/dockge /opt/dockge |

### Permessi di esecuzione
```
chmod +x update-lxc.sh
```

---

## Utilizzo

Lo script richiede uno o piu identificatori LXC (ID o nome parziale) come argomento.

### 1. Modalita Dry Run (Simulazione)
Visualizza cosa accadrebbe senza eseguire modifiche reali:

| Comando | Descrizione |
|---------|-------------|
| ./update-lxc.sh --dry-run 8006 | Simula aggiornamento per LXC ID 8006 |
| ./update-lxc.sh all --dry-run | Simula aggiornamento per tutti gli LXC attivi |
| ./update-lxc.sh hom --dry-run | Simula aggiornamento per LXC con hostname contenente "hom" (es. Homarr) |

### 2. Aggiornamento Reale
Esegue l'aggiornamento con snapshot:

| Comando | Descrizione |
|---------|-------------|
| ./update-lxc.sh 8006 8011 | Aggiorna solo gli LXC con ID 8006 e 8011 |
| ./update-lxc.sh all | ATTENZIONE: Aggiorna tutti gli LXC attivi con Docker |
| ./update-lxc.sh immich | Aggiorna LXC con hostname contenente "immich" |

---

## Logica di Sicurezza e Rollback

Ogni aggiornamento segue questi passaggi:

1. Verifica Docker -> se non installato, l'LXC viene saltato  
2. Snapshot temporaneo -> se fallisce, il processo si interrompe  
3. Aggiornamento stack -> docker compose pull && docker compose up -d  
   - Prima Dockge  
   - Poi tutti gli altri stack rilevati  
4. Successo totale -> snapshot eliminato  
   Errore rilevato -> rollback immediato allo snapshot iniziale e successiva eliminazione  

---

## English Documentation

The update-lxc.sh script automates updating Docker Compose stacks inside LXC containers on a Proxmox host.

### Key Features
- Automatic Snapshot and Rollback  
- Docker Compose scanning  
- Dry Run mode (--dry-run)  
- Intelligent filtering (IDs, partial names, all)  

### Initial Configuration
Modify in USER CONFIG:

| Variable | Description | Default |
|----------|-------------|---------|
| SCAN_ROOT | Directory inside LXC to search for docker-compose.yml | /root /opt/stacks |
| DOCKGE_PATH | Path for Dockge stack (updated first) | /root/dockge_install/dockge /opt/dockge |

### Usage
- Dry Run: ./update-lxc.sh --dry-run 8006  
- Live Update: ./update-lxc.sh 8006 8011  

### Security and Rollback Logic
1. Docker check  
2. Snapshot creation  
3. Update stacks (docker compose pull && docker compose up -d)  
4. Success -> snapshot deleted  
   Failure -> rollback + snapshot deletion  

---

## Licenza

Questo script e distribuito per uso personale e amministrativo.  
Usalo con cautela: l'opzione "all" puo modificare tutti i container attivi.

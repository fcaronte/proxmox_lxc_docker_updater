root@PC-Galliate:~# ./update-lxc.sh 8005 8006
Aggiornamento LXC Docker (v1.6.4 (Report Fix)) - Host: 192.168.178.10
Radici di Scansione Docker: /root /opt/stacks
--------------------------------------------------------
ID LXC da processare: 8005 8006 

--------------------------------------------------------
--------------------------------------------------------
#### AVVIO PROCESSO PER LXC ID 8005 (Syncthing) ####
Snapshot creato. Avvio aggiornamento Docker...
   -> Aggiornamento selettivo Dockge (/root/dockge_install/dockge) in /root/dockge_install/dockge...
   -> Pulling nuove immagini per Dockge (/root/dockge_install/dockge)...
   -> Avvio/Aggiornamento solo dei servizi attivi: (dockge)...
   -> Dockge (/root/dockge_install/dockge) aggiornato con successo (solo servizi attivi riavviati).
   -> ATTENZIONE: Nessun file compose trovato in /opt/dockge. Stack Dockge (/opt/dockge) saltato.
Inizio scansione Docker Compose nei percorsi: /root /opt/stacks...
   -> Aggiornamento selettivo syncthing in /root/syncthing...
   -> Pulling nuove immagini per syncthing...
   -> Avvio/Aggiornamento solo dei servizi attivi: (syncthing)...
   -> syncthing aggiornato con successo (solo servizi attivi riavviati).
--------------------------------------------------------
AGGIORNAMENTO RIUSCITO per LXC 8005.
Configurazione KEEP_LAST_SNAPSHOT=true: lo snapshot Creazione snapshot AUTO_UPDATE_SNAP_20251205003510_8005...
AUTO_UPDATE_SNAP_20251205003510_8005 è ora L'UNICO MANTENUTO.
   Esecuzione Pulizia Snapshot (Mantieni solo l'ultimo di successo)...
   Trovati 2 snapshot. Verranno rimossi i vecchi, mantenendo solo AUTO_UPDATE_SNAP_20251205003510_8005.
   Rimozione snapshot obsoleto: AUTO_UPDATE_SNAP_20251205002951_8005...
  Snapshot AUTO_UPDATE_SNAP_20251205002951_8005 rimosso con successo.
   Avvio pulizia spazio Docker (Immagini/Container non utilizzati) su LXC 8005...
   Pulizia Docker System completata.
Nota: Tutti gli snapshot precedenti sono stati processati per la rimozione.
#### FINE PROCESSO PER LXC ID 8005 ####
--------------------------------------------------------
#### AVVIO PROCESSO PER LXC ID 8006 (Homarr) ####
Snapshot creato. Avvio aggiornamento Docker...
   -> Aggiornamento selettivo Dockge (/root/dockge_install/dockge) in /root/dockge_install/dockge...
   -> Pulling nuove immagini per Dockge (/root/dockge_install/dockge)...
   -> Avvio/Aggiornamento solo dei servizi attivi: (dockge)...
   -> Dockge (/root/dockge_install/dockge) aggiornato con successo (solo servizi attivi riavviati).
   -> ATTENZIONE: Nessun file compose trovato in /opt/dockge. Stack Dockge (/opt/dockge) saltato.
Inizio scansione Docker Compose nei percorsi: /root /opt/stacks...
   -> Aggiornamento selettivo homarr in /root/homarr...
   -> Pulling nuove immagini per homarr...
   -> Avvio/Aggiornamento solo dei servizi attivi: (homarr)...
   -> homarr aggiornato con successo (solo servizi attivi riavviati).
--------------------------------------------------------
AGGIORNAMENTO RIUSCITO per LXC 8006.
Configurazione KEEP_LAST_SNAPSHOT=true: lo snapshot Creazione snapshot AUTO_UPDATE_SNAP_20251205003527_8006...
AUTO_UPDATE_SNAP_20251205003527_8006 è ora L'UNICO MANTENUTO.
   Esecuzione Pulizia Snapshot (Mantieni solo l'ultimo di successo)...
   Trovati 2 snapshot. Verranno rimossi i vecchi, mantenendo solo AUTO_UPDATE_SNAP_20251205003527_8006.
   Rimozione snapshot obsoleto: AUTO_UPDATE_SNAP_20251205003026_8006...
  Snapshot AUTO_UPDATE_SNAP_20251205003026_8006 rimosso con successo.
   Avvio pulizia spazio Docker (Immagini/Container non utilizzati) su LXC 8006...
   Pulizia Docker System completata.
Nota: Tutti gli snapshot precedenti sono stati processati per la rimozione.
#### FINE PROCESSO PER LXC ID 8006 ####

========================================================
===== REPORT FINALE AGGIORNAMENTO LXC & DOCKER =====
========================================================
--- Dettagli degli Aggiornamenti Riusciti ---
🟡 LXC 8005 - Dockge (/root/dockge_install/dockge): Nessun aggiornamento necessario.
🟡 LXC 8005 - syncthing: Nessun aggiornamento necessario.
🟡 LXC 8006 - Dockge (/root/dockge_install/dockge): Nessun aggiornamento necessario.
🟡 LXC 8006 - homarr: Nessun aggiornamento necessario.
---
--- Stato Finale LXC ---
LXC 8005 (Syncthing) → OK (Aggiornamento Saltato/Precedente)
LXC 8006 (Homarr) → OK (Aggiornamento Saltato/Precedente)
========================================================
root@PC-Galliate:~# ./update-lxc.sh clean all
Aggiornamento LXC Docker (v1.6.4 (Report Fix)) - Host: 192.168.178.10
--------------------------------------------------------
ID LXC da processare: 8005 8006 8007 8011 8013 8014 8015 8018 8019 8254 

--------------------------------------------------------
===== AVVIO PULIZIA MANUALE SNAPSHOTS =====
#### AVVIO PULIZIA MANUALE SNAPSHOT PER LXC ID 8005 (Syncthing) ####
   -> Trovati snapshot da rimuovere:
   -> Tentativo di rimozione snapshot: AUTO_UPDATE_SNAP_20251205003510_8005...
  ✅ AUTO_UPDATE_SNAP_20251205003510_8005 rimosso con successo.
#### PULIZIA COMPLETA PER LXC ID 8005 (Syncthing). 1 snapshot processati. ####
---
#### AVVIO PULIZIA MANUALE SNAPSHOT PER LXC ID 8006 (Homarr) ####
   -> Trovati snapshot da rimuovere:
   -> Tentativo di rimozione snapshot: AUTO_UPDATE_SNAP_20251205003527_8006...
  ✅ AUTO_UPDATE_SNAP_20251205003527_8006 rimosso con successo.
#### PULIZIA COMPLETA PER LXC ID 8006 (Homarr). 1 snapshot processati. ####
---
#### AVVIO PULIZIA MANUALE SNAPSHOT PER LXC ID 8007 (Guacamole) ####
   -> Nessuno snapshot di pulizia automatica (AUTO_UPDATE_SNAP) trovato per LXC 8007.
---
#### AVVIO PULIZIA MANUALE SNAPSHOT PER LXC ID 8011 (NextCloud) ####
   -> Nessuno snapshot di pulizia automatica (AUTO_UPDATE_SNAP) trovato per LXC 8011.
---
#### AVVIO PULIZIA MANUALE SNAPSHOT PER LXC ID 8013 (Tailscale) ####
   -> Nessuno snapshot di pulizia automatica (AUTO_UPDATE_SNAP) trovato per LXC 8013.
---
#### AVVIO PULIZIA MANUALE SNAPSHOT PER LXC ID 8014 (Immich) ####
   -> Nessuno snapshot di pulizia automatica (AUTO_UPDATE_SNAP) trovato per LXC 8014.
---
#### AVVIO PULIZIA MANUALE SNAPSHOT PER LXC ID 8015 (Dockge) ####
   -> Nessuno snapshot di pulizia automatica (AUTO_UPDATE_SNAP) trovato per LXC 8015.
---
#### AVVIO PULIZIA MANUALE SNAPSHOT PER LXC ID 8018 (Frigate) ####
   -> Nessuno snapshot di pulizia automatica (AUTO_UPDATE_SNAP) trovato per LXC 8018.
---
#### AVVIO PULIZIA MANUALE SNAPSHOT PER LXC ID 8019 (Nginx) ####
   -> Nessuno snapshot di pulizia automatica (AUTO_UPDATE_SNAP) trovato per LXC 8019.
---
#### AVVIO PULIZIA MANUALE SNAPSHOT PER LXC ID 8254 (Pihole) ####
   -> Nessuno snapshot di pulizia automatica (AUTO_UPDATE_SNAP) trovato per LXC 8254.
---
===== PULIZIA MANUALE COMPLETA =====
root@PC-Galliate:~# 

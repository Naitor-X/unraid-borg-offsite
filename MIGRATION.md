# Migration: Unraid Backup-Server → Ubuntu + Borg

Diese Anleitung richtet sich an alle, die bisher einen **Unraid-Server als rsync-Backup-Ziel** betrieben haben und auf Borg umsteigen wollen — ohne die alten Daten zu verlieren.

## Übersicht

```
VORHER                              NACHHER
┌─────────────────────┐             ┌──────────────────────────────────┐
│  Unraid Backup-Server│             │  Ubuntu Backup-Server            │
│  HDD (rsync)        │     →→→     │  SSD (OS) + HDD (/repos)        │
│  alte rsync-Daten   │             │  Borg-Repos + rsync als Fallback │
└─────────────────────┘             └──────────────────────────────────┘
```

**Strategie:** Drei Phasen — HDD umziehen → Borg parallel aufbauen → rsync-Daten löschen.  
Die alten rsync-Daten bleiben unberührt bis Borg stabil läuft.

---

## Phase 1 — HDD ausbauen (aus dem alten Unraid-Server)

1. Im Unraid-WebUI: **Main → Array Stop**
2. Unraid herunterfahren: **Main → Shutdown**
3. HDD ausbauen

> Unraid formatiert seine Daten-HDDs als XFS — Ubuntu liest das nativ, kein Konvertieren nötig.

---

## Phase 2 — Ubuntu-Server einrichten

### 2.1 HDD einbauen und mounten

HDD in den Ubuntu-Rechner einbauen, dann booten.

```bash
# Prüfen ob HDD erkannt und UUID ermitteln
lsblk -f
# Notiere die UUID der HDD-Partition (z.B. sdb1)

# Mountpoint anlegen
mkdir -p /repos

# Einmalig testen
mount /dev/sdb1 /repos

# Inhalt prüfen — rsync-Daten müssen sichtbar sein
ls /repos
```

### 2.2 Dauerhaft in /etc/fstab eintragen

```bash
echo "UUID=<UUID-DER-HDD>  /repos  xfs  defaults,nofail  0  2" >> /etc/fstab

# Testen ob fstab korrekt ist
mount -a
```

### 2.3 Unraid-interne Verzeichnisse löschen

Diese Verzeichnisse legt Unraid selbst an und werden nicht mehr gebraucht:

```bash
rm -rf /repos/appdata
rm -rf /repos/domains
rm -rf /repos/isos
rm -rf /repos/system
```

### 2.4 Verzeichnisstruktur anlegen

```bash
# Borg-Repos kommen direkt unter /repos/<servername>
# Kein eigenes Unterverzeichnis nötig
mkdir -p /repos
```

Nach dieser Phase sieht `/repos` so aus:

```
/repos/
  server1/     ← alte rsync-Daten, noch behalten
  server2/     ← alte rsync-Daten, noch behalten
               ← neue Borg-Repos entstehen hier später: /repos/unraid1/
```

### 2.5 Pakete installieren

```bash
apt update && apt upgrade -y
apt install -y borgbackup wireguard
```

---

## Phase 3 — Borg-Server aufsetzen

Jetzt die `ANLEITUNG.md` ab **Teil 1** abarbeiten.

### 3.1 SSH-Keys anlegen

```bash
mkdir -p /etc/borg-keys

# Append-only Keys pro Quell-Server
ssh-keygen -t ed25519 -f /etc/borg-keys/unraid1_borg -N "" -C "borg-unraid1-appendonly"
ssh-keygen -t ed25519 -f /etc/borg-keys/unraid2_borg -N "" -C "borg-unraid2-appendonly"

# Admin-Key für Prune (läuft lokal auf diesem Server)
ssh-keygen -t ed25519 -f /etc/borg-keys/admin_borg -N "" -C "borg-admin-prune"
```

### 3.2 Borg-Benutzer anlegen

```bash
useradd -m -s /bin/bash borg
mkdir -p /home/borg/.ssh
chmod 700 /home/borg/.ssh
```

### 3.3 authorized_keys konfigurieren

```bash
cat > /home/borg/.ssh/authorized_keys << 'EOF'
command="borg serve --append-only --restrict-to-path /repos/unraid1",restrict ssh-ed25519 INHALT_VON_unraid1_borg.pub
command="borg serve --append-only --restrict-to-path /repos/unraid2",restrict ssh-ed25519 INHALT_VON_unraid2_borg.pub
command="borg serve --restrict-to-path /repos",restrict ssh-ed25519 INHALT_VON_admin_borg.pub
EOF

chown -R borg:borg /home/borg/.ssh
chmod 600 /home/borg/.ssh/authorized_keys
```

Den jeweiligen Public-Key-Inhalt einfügen:
```bash
cat /etc/borg-keys/unraid1_borg.pub
```

### 3.4 borg-prune.sh deployen

Pfade in `borg-prune.sh` auf die eigenen Server anpassen:

```bash
prune_jobs=(
  "/repos/unraid1"  "unraid1-appdata-*"    14  8  12  3
  "/repos/unraid1"  "unraid1-databases-*"  30 12  24  5
  "/repos/unraid2"  "unraid2-appdata-*"    14  8  12  3
)
repos_mount="/repos"
```

```bash
mkdir -p /opt/borg-prune /etc/borg-prune
cp borg-prune.sh /opt/borg-prune/borg-prune.sh
chmod +x /opt/borg-prune/borg-prune.sh

cp .env.example /etc/borg-prune/.env
chmod 600 /etc/borg-prune/.env
nano /etc/borg-prune/.env   # Passphrase eintragen

# Cron: täglich 03:00
crontab -e
# Eintragen: 0 3 * * * /opt/borg-prune/borg-prune.sh >> /var/log/borg-prune/cron.log 2>&1
```

---

## Phase 4 — Borg-Clients einrichten (Quell-Server)

Auf jedem Unraid-Server, der sichern soll, `ANLEITUNG.md` **Teil 2** abarbeiten.

Beispielkonfiguration für `borg-backup.sh`:

**unraid1:**
```bash
hostname="unraid1"
backup_jobs=(
  "/mnt/user/backup/appdata"    "ssh://10.8.0.1/repos/unraid1"  "appdata"    14  8  12  3
  "/mnt/user/backup/databases"  "ssh://10.8.0.1/repos/unraid1"  "databases"  30 12  24  5
)
```

**unraid2:**
```bash
hostname="unraid2"
backup_jobs=(
  "/mnt/user/backup/appdata"  "ssh://10.8.0.1/repos/unraid2"  "appdata"  14  8  12  3
)
```

Den **Append-only Private Key** vom Ubuntu-Server auf den jeweiligen Unraid-Server kopieren:
```bash
# Auf Ubuntu-Server: Key anzeigen
cat /etc/borg-keys/unraid1_borg

# Auf Unraid-Server: Key ablegen
mkdir -p /etc/borg-backup
nano /etc/borg-backup/ssh_key   # Inhalt einfügen
chmod 600 /etc/borg-backup/ssh_key
```

---

## Phase 5 — Erstbackup

```bash
# Repos initialisieren (noch kein Backup)
# Im Unraid User Scripts Plugin: BorgBackup-Script mit --init-only starten
bash /boot/config/plugins/user.scripts/scripts/BorgBackup-Script/script --init-only

# Borg-Key sofort exportieren und ausdrucken!
borg key export ssh://10.8.0.1/repos/unraid1 /tmp/unraid1.borg.key
cat /tmp/unraid1.borg.key
# → Ausdrucken → Datei löschen
rm /tmp/unraid1.borg.key

# Dry-Run zur Kontrolle
bash /boot/config/plugins/user.scripts/scripts/BorgBackup-Script/script --dry-run

# Erstes echtes Backup (dauert beim ersten Mal lang)
bash /boot/config/plugins/user.scripts/scripts/BorgBackup-Script/script
```

---

## Phase 6 — Stabilisierungsphase (2–4 Wochen)

- Borg läuft täglich via Cron
- Uptime Kuma Monitor überwacht den Heartbeat
- Alte rsync-Daten liegen noch unberührt auf der HDD
- **Restore-Test durchführen** (siehe `ANLEITUNG.md` Teil 3)

---

## Phase 7 — Altes System abschalten

Erst wenn gilt:
- [x] Borg läuft seit mind. 2 Wochen ohne Fehler
- [x] Restore-Test erfolgreich
- [x] Uptime Kuma meldet täglich grün

```bash
# Alte rsync-Daten löschen
rm -rf /repos/server1
rm -rf /repos/server2
# usw. für alle alten rsync-Verzeichnisse

# Speicherplatz prüfen
df -h /repos
```

Alter Unraid-Backup-Server kann jetzt endgültig abgeschaltet werden.

---

## Schnellreferenz: Was liegt wo

| Pfad | Inhalt |
|------|--------|
| `/repos/` | Mountpoint der Backup-HDD |
| `/repos/unraid1/` | Borg-Repo für Server 1 |
| `/repos/unraid2/` | Borg-Repo für Server 2 |
| `/opt/borg-prune/` | `borg-prune.sh` Script |
| `/etc/borg-prune/.env` | Passphrase (chmod 600) |
| `/etc/borg-keys/` | SSH-Keys für Borg |
| `/var/log/borg-prune/` | Prune-Logs |

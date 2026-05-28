# Borg Backup — Schritt-für-Schritt Anleitung

## Übersicht

```
Unraid Main-Server (1–5)          Offsite Backup-Server (Ubuntu)
┌─────────────────────────┐       ┌──────────────────────────────┐
│  borg-backup.sh         │       │  /repos/unraid-1/  (Borg-Repo│
│  läuft als Cron-Job     │──SSH──│  /repos/unraid-2/            │
│  WireGuard Client       │  VPN  │  WireGuard Server            │
│                         │       │  borg-prune.sh (Cron)        │
└─────────────────────────┘       └──────────────────────────────┘
```

**Sicherheitsmodell:**  
Unraid-Server können ausschließlich neue Archive *hinzufügen* (append-only). Löschen und Prune sind vom Backup-Server aus gesperrt. Ransomware auf einem Unraid-Server kann die Backup-History nicht vernichten.

---

## Teil 1: Backup-Server einrichten (einmalig)

### 1.1 Ubuntu Server aufsetzen

```bash
apt update && apt upgrade -y
apt install -y borgbackup wireguard
```

Verzeichnis für Repos anlegen:
```bash
mkdir -p /repos
# Empfehlung: eigene Festplatte oder Volume unter /repos mounten
```

### 1.2 WireGuard Server konfigurieren

Schlüsselpaar erzeugen:
```bash
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key
```

`/etc/wireguard/wg0.conf` auf dem Backup-Server:
```ini
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = <SERVER_PRIVATE_KEY>

# Unraid-Server 1
[Peer]
PublicKey = <UNRAID1_PUBLIC_KEY>
AllowedIPs = 10.8.0.2/32

# Unraid-Server 2
[Peer]
PublicKey = <UNRAID2_PUBLIC_KEY>
AllowedIPs = 10.8.0.3/32
```

WireGuard starten:
```bash
systemctl enable --now wg-quick@wg0
```

Firewall-Regel (UFW):
```bash
ufw allow 51820/udp
ufw allow ssh
ufw enable
```

### 1.3 SSH-Keys für Borg anlegen

Pro Unraid-Server einen eigenen **Append-only Key** anlegen:
```bash
# Auf dem Backup-Server als root
ssh-keygen -t ed25519 -f /etc/borg-keys/unraid1_borg -N "" -C "borg-unraid1-appendonly"
ssh-keygen -t ed25519 -f /etc/borg-keys/unraid2_borg -N "" -C "borg-unraid2-appendonly"
```

Einen separaten **Admin-Key** für Prune:
```bash
ssh-keygen -t ed25519 -f /etc/borg-keys/admin_borg -N "" -C "borg-admin-prune"
```

### 1.4 `authorized_keys` konfigurieren

`~/.ssh/authorized_keys` des Backup-Server-Benutzers (z.B. `borg`):
```
command="borg serve --append-only --restrict-to-path /repos/unraid1",restrict ssh-ed25519 AAAA... borg-unraid1-appendonly
command="borg serve --append-only --restrict-to-path /repos/unraid2",restrict ssh-ed25519 AAAA... borg-unraid2-appendonly
command="borg serve --restrict-to-path /repos",restrict ssh-ed25519 AAAA... borg-admin-prune
```

> **Hinweis:** `--append-only` verhindert `borg delete` und `borg prune` vom Client aus.  
> Der Admin-Key hat kein `--append-only` — nur für den Prune-Cron verwenden!

### 1.5 `borg-prune.sh` deployen

```bash
cp borg-prune.sh /opt/borg-prune/borg-prune.sh
chmod +x /opt/borg-prune/borg-prune.sh

mkdir -p /etc/borg-prune
cp .env.example /etc/borg-prune/.env
chmod 600 /etc/borg-prune/.env
# Passphrase eintragen!
nano /etc/borg-prune/.env
```

Cron einrichten (täglich um 03:00):
```bash
crontab -e
# Eintragen:
0 3 * * * /opt/borg-prune/borg-prune.sh >> /var/log/borg-prune/cron.log 2>&1
```

---

## Teil 2: Pro Unraid Main-Server

### 2.1 borgbackup installieren (Standalone Binary)

Unraid nutzt Slackware/glibc — Package-Manager-Versionen haben oft fehlende Python-Abhängigkeiten. Standalone Binary ist zuverlässiger.

**Binary herunterladen:**
```bash
mkdir -p /boot/bin
wget -O /boot/bin/borg https://github.com/borgbackup/borg/releases/download/1.4.4/borg-linux-glibc231-x86_64
```

> Exakten Dateinamen für künftige Versionen prüfen:
> ```bash
> wget -q -O- "https://api.github.com/repos/borgbackup/borg/releases/tags/1.4.4" | grep "browser_download_url" | grep linux
> ```

**Binary installieren:**
```bash
cp /boot/bin/borg /usr/local/bin/borg && chmod 755 /usr/local/bin/borg
```

**Funktionstest:**
```bash
borg --version
# → borg 1.4.4

borg init --encryption=none /tmp/borg-test && borg info /tmp/borg-test
```

**Reboot-persistent machen** (in `/boot/config/go` eintragen):
```bash
cat >> /boot/config/go << 'EOF'

cp /boot/bin/borg /usr/local/bin/borg
chmod 755 /usr/local/bin/borg
EOF
```

> `/boot/config/go` ist das Standard-Startup-Script von Unraid — genau für solche Einträge gedacht.

### 2.2 WireGuard Client konfigurieren

Schlüsselpaar erzeugen (auf dem Unraid-Server):
```bash
wg genkey | tee /etc/wireguard/client_private.key | wg pubkey > /etc/wireguard/client_public.key
chmod 600 /etc/wireguard/client_private.key
```

Den Public Key dem Backup-Server mitteilen → in `wg0.conf` als Peer eintragen.

`/etc/wireguard/wg0.conf` auf dem Unraid-Server:
```ini
[Interface]
Address = 10.8.0.2/32
PrivateKey = <CLIENT_PRIVATE_KEY>

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
Endpoint = <BACKUP_SERVER_IP_ODER_DOMAIN>:51820
AllowedIPs = 10.8.0.1/32
PersistentKeepalive = 25
```

> **Hinweis:** `AllowedIPs = 10.8.0.1/32` — nur der Backup-Server läuft über den VPN-Tunnel.  
> Der restliche Traffic geht weiterhin direkt ins Internet.

### 2.3 SSH-Key auf Unraid-Server hinterlegen

> **Unraid-Spezifik:** `/etc/` ist auf Unraid ein RAM-Filesystem (tmpfs) — nach jedem Reboot leer.  
> Alle persistenten Configs gehören nach `/boot/config/` (liegt auf dem USB-Stick).

Den **Append-only Private Key** des Backup-Servers auf den Unraid-Server kopieren:
```bash
mkdir -p /boot/config/borg-backup
cp unraid1_borg /boot/config/borg-backup/ssh_key
chmod 600 /boot/config/borg-backup/ssh_key
```

SSH-Config anlegen damit Borg den richtigen Key und User verwendet:
```bash
mkdir -p /root/.ssh
cat > /root/.ssh/config << 'EOF'
Host 10.8.0.1
    User borg
    IdentityFile /boot/config/borg-backup/ssh_key
    StrictHostKeyChecking accept-new
EOF
chmod 600 /root/.ssh/config
```

SSH-Config reboot-persistent machen (in `/boot/config/go` eintragen):
```bash
cat >> /boot/config/go << 'EOF'

# Borg SSH-Config wiederherstellen
mkdir -p /root/.ssh
cp /boot/config/borg-backup/ssh_config /root/.ssh/config 2>/dev/null || true
chmod 600 /root/.ssh/config 2>/dev/null || true
EOF

# SSH-Config auch unter /boot ablegen damit der go-Eintrag sie findet
cp /root/.ssh/config /boot/config/borg-backup/ssh_config
```

> **Wichtig:** `User borg` ist zwingend — sonst versucht Borg als `root` zu verbinden und der SSH-Key wird nicht akzeptiert.

### 2.4 `.env`-Datei anlegen

`.env` direkt unter `/boot/` anlegen (überlebt Reboots):
```bash
mkdir -p /boot/config/borg-backup
cat > /boot/config/borg-backup/.env << 'EOF'
BORG_PASSPHRASE="langes-sicheres-passwort-hier"
EOF
chmod 600 /boot/config/borg-backup/.env
```

**Wichtig:** Starkes, zufälliges Passwort wählen (min. 32 Zeichen).  
Beispiel generieren: `openssl rand -base64 32`

> `/etc/borg-backup/.env` funktioniert **nur bis zum nächsten Reboot** — nach einem Neustart ist `/etc/` leer.  
> Das `borg-backup.sh` Script referenziert daher `/boot/config/borg-backup/.env`.

### 2.5 `borg-backup.sh` konfigurieren

Die Vorlage `borg-backup.sh` anpassen — mindestens diese Werte setzen:
- `hostname` — eindeutiger Name des Servers (z.B. `unraid1`)
- `backup_jobs` — Quellpfade und Repo-URLs

Das Script wird in Schritt 2.6 direkt über das User Scripts Plugin eingefügt.

### 2.6 User Scripts einrichten

Unraid speichert `/etc/` im RAM — Cron-Einträge dort sind nach einem Reboot weg. Das **User Scripts Plugin** speichert Scripts unter `/boot/` und ist reboot-persistent.

**Backup-Script anlegen (noch ohne Schedule):**
1. Unraid UI → **Settings → User Scripts → Add New Script**
2. Name: `BorgBackup-Script`
3. Zahnrad-Icon → **Edit Script**
4. Kompletten Inhalt von `borg-backup.sh` (mit angepassten Werten) einfügen → **Save**

**Stop-Script anlegen:**
1. **Add New Script**
2. Name: `BorgBackup-Stop`
3. Inhalt:
```bash
#!/bin/bash
pkill -SIGTERM -f BorgBackup-Script
```
4. **Schedule → Custom** → `0 6 * * *`

> Borg speichert beim SIGTERM einen Checkpoint — das nächste Backup setzt dort fort.

### 2.7 Repos initialisieren und Key exportieren

Repos initialisieren (kein Backup, nur Init):
```bash
bash /boot/config/plugins/user.scripts/scripts/BorgBackup-Script/script --init-only
```

**Danach Rechte auf dem Backup-Server korrigieren** (auf dem Backup-Server):
```bash
chown -R borg:borg /repos/HOSTNAME
```

> Ohne diesen Schritt schlägt `borg info` fehl weil die Repo-Dateien als `root` angelegt wurden.

**Jetzt sofort den Borg-Key exportieren und ausdrucken:**
```bash
BORG_PASSPHRASE="..." borg key export ssh://10.8.0.1/repos/HOSTNAME /tmp/HOSTNAME.borg.key
cat /tmp/HOSTNAME.borg.key
# → Inhalt ausdrucken und in den Safe legen
rm /tmp/HOSTNAME.borg.key
```

Erstes vollständiges Backup (Dry-Run zur Kontrolle):
```bash
bash /boot/config/plugins/user.scripts/scripts/BorgBackup-Script/script --dry-run
```

Erstes echtes Backup:
```bash
bash /boot/config/plugins/user.scripts/scripts/BorgBackup-Script/script
```

Ergebnis prüfen:
```bash
BORG_PASSPHRASE="..." borg list ssh://10.8.0.1/repos/HOSTNAME
```

**Schedule aktivieren** (nach erfolgreichem ersten Backup):

Unraid UI → User Scripts → `BorgBackup-Script` → **Schedule → Custom** → `0 22 * * *`

> Wenn mehrere Unraid-Server auf denselben Backup-Server sichern, Startzeiten versetzen (z.B. 22:00 und 23:00) um gleichzeitige Last zu vermeiden.

### 2.8 Uptime Kuma Monitor einrichten

1. In Uptime Kuma: **Add New Monitor** → Typ: **Push**
2. Name: `Borg Backup unraid1`
3. Heartbeat-Intervall: `1440` Minuten (täglich)
4. Grace Period: `120` Minuten
5. Die generierte Push-URL in `borg-backup.sh` → `healthcheck_url` eintragen

---

## Teil 3: Disaster Recovery

### Archive auflisten

```bash
# WireGuard manuell starten falls nicht aktiv
wg-quick up wg0

borg list ssh://10.8.0.1/repos/unraid1
# Ausgabe:
# unraid1-appdata-2026-05-22T22:00     ...
# unraid1-databases-2026-05-22T22:05   ...
```

### Einzelne Dateien wiederherstellen (FUSE Mount)

```bash
mkdir -p /mnt/restore
borg mount ssh://10.8.0.1/repos/unraid1::unraid1-appdata-2026-05-22T22:00 /mnt/restore

# Dateien aus /mnt/restore suchen und kopieren
ls /mnt/restore
cp /mnt/restore/pfad/zur/datei /ziel/

borg umount /mnt/restore
```

### Vollständiges Archiv extrahieren

```bash
mkdir -p /mnt/restore
cd /mnt/restore
borg extract ssh://10.8.0.1/repos/unraid1::unraid1-appdata-2026-05-22T22:00
# Alle Dateien befinden sich jetzt unter /mnt/restore/
```

### Schlüssel wiederherstellen (nach Totalverlust)

```bash
# Ausgedruckten Key abtippen:
borg key import ssh://10.8.0.1/repos/unraid1 /tmp/recovered.key
```

---

## Teil 4: Wartung

### Quartalsweise Restore-Test (Pflicht!)

**Alle 3 Monate** einen Restore-Test durchführen:

```bash
# 1. Zufälliges Archiv wählen
borg list ssh://10.8.0.1/repos/unraid1 | shuf | head -3

# 2. Einzelne Dateien mounten und prüfen
mkdir -p /mnt/restore-test
borg mount ssh://10.8.0.1/repos/unraid1::ARCHIVNAME /mnt/restore-test
ls -la /mnt/restore-test/
# → Stichproben auf Integrität und Lesbarkeit prüfen

# 3. Aufräumen
borg umount /mnt/restore-test

# 4. Ergebnis kurz notieren (Datum, Archiv, Ergebnis)
```

> Ein Backup das nie getestet wurde ist kein Backup.

### Manuelle Prune-Kontrolle

```bash
# Vorschau: welche Archive würden gelöscht?
borg prune \
  --glob-archives 'unraid1-appdata-*' \
  --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --keep-yearly 3 \
  --list --dry-run \
  /repos/unraid1
```

### Speicherplatz-Übersicht

```bash
borg info /repos/unraid1
df -h /repos
```

---

## Troubleshooting

### WireGuard verbindet nicht

```bash
# Status prüfen
wg show wg0
# Logs
journalctl -u wg-quick@wg0 -n 50
```

### Borg SSH-Verbindung fehlgeschlagen

```bash
# Manuell testen (vom Unraid-Server aus)
ssh -i /etc/borg-backup/ssh_key borg@10.8.0.1 -- borg serve --version
```

### Checkpoint-Archiv manuell entfernen

Wenn ein unterbrochenes Backup nicht fortgesetzt werden soll:
```bash
# Nur vom Backup-Server mit Admin-Key möglich!
borg delete /repos/unraid1::unraid1-appdata-2026-05-22T22:00.checkpoint
```

### Passphrase vergessen

Ohne Passphrase sind die Daten **unwiederbringlich verloren**.  
→ Ausgedruckten Zettel aus dem Safe holen.

### PermissionError: `/repos/HOSTNAME/data/X/XXXX` (Backup-Server)

**Symptom:** `borg info` oder `borg create` schlägt fehl mit `PermissionError: [Errno 13] Permission denied`.

**Ursache:** `borg compact` und `borg prune` laufen auf dem Backup-Server als `root`. Neu erstellte Segment-, Index- und Hints-Dateien gehören dann `root:root` statt `borg:borg`. Der `borg`-SSH-User (der beim Backup-Client-Zugriff verwendet wird) kann diese Dateien nicht lesen.

**Sofort-Fix** (auf dem Backup-Server als root):
```bash
find /repos/HOSTNAME -not -user borg -exec chown borg:borg {} +
```

**Dauerhafter Fix:** Im aktuellen `borg-prune.sh` ist dieser `find/chown` nach jedem `borg compact` bereits eingebaut — tritt nach dem nächsten Prune-Lauf nicht mehr auf.

### WireGuard: "RTNETLINK answers: File exists" beim Backup-Start

**Symptom:** Das Backup-Script schlägt beim WireGuard-Start fehl wenn das Interface bereits aktiv ist (z.B. nach manuellem `wg-quick up` oder einem vorherigen Script-Lauf).

**Ursache:** Altes Script-Verhalten: `wg-quick up` wurde immer versucht, auch wenn das Interface schon oben war.

**Fix:** Das aktuelle `borg-backup.sh` prüft per `ip link show` ob das Interface bereits aktiv ist und überspringt den Start in diesem Fall. Die Cleanup-Funktion trennt WireGuard außerdem nur dann, wenn das Script es selbst gestartet hat.

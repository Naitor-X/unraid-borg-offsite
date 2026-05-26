# unraid-borg-offsite

Automatisiertes Offsite-Backup für Unraid — ransomware-resistent via Append-only SSH über WireGuard-VPN.

## Architektur

```
Unraid Main-Server (1–n)          Offsite Backup-Server (Ubuntu)
┌─────────────────────────┐       ┌──────────────────────────────┐
│  borg-backup.sh         │       │  /repos/unraid-1/  (Borg-Repo│
│  läuft als Cron-Job     │──SSH──│  /repos/unraid-2/            │
│  WireGuard Client       │  VPN  │  WireGuard Server            │
│                         │       │  borg-prune.sh (Cron)        │
└─────────────────────────┘       └──────────────────────────────┘
```

**Sicherheitsmodell:** Unraid-Server können ausschließlich neue Archive *hinzufügen* (append-only). Löschen und Prune sind vom Backup-Server aus gesperrt. Ransomware auf einem Unraid-Server kann die Backup-History nicht vernichten.

## Features

- **Append-only Push** — Unraid-Server können keine Archive löschen oder verändern
- **Verschlüsselung** — `repokey-blake2`: Daten auf dem Backup-Server sind ohne Passphrase unlesbar
- **WireGuard VPN** — Backup-Traffic läuft verschlüsselt über einen isolierten Tunnel
- **Resume bei Abbruch** — unterbrochene Backups werden beim nächsten Lauf fortgesetzt (Checkpoint)
- **Mehrere Jobs pro Server** — verschiedene Quellpfade mit individuellen Retention-Regeln
- **Healthcheck** — optionaler Uptime Kuma Push-Monitor überwacht den täglichen Heartbeat
- **Unraid-Benachrichtigungen** — Fehler erscheinen in der Unraid-Weboberfläche
- **Log-Rotation** — automatisches Aufräumen alter Log-Dateien

## Voraussetzungen

**Backup-Server:**
- Ubuntu 22.04 oder neuer
- `borgbackup`, `wireguard`
- Eigene Festplatte oder Volume unter `/repos` empfohlen

**Unraid-Server (je):**
- Unraid 6.x oder neuer
- [User Scripts Plugin](https://forums.unraid.net/topic/48286-plugin-user-scripts/) für reboot-persistente Cron-Jobs
- borgbackup Standalone Binary (Installationsanleitung in `ANLEITUNG.md`)

## Dateien

| Datei | Beschreibung |
|-------|-------------|
| `borg-backup.sh` | Backup-Script für Unraid-Server — auf jedem Quell-Server anpassen und deployen |
| `borg-prune.sh` | Prune & Wartung für den Ubuntu Backup-Server |
| `.env.example` | Vorlage für Secrets (`BORG_PASSPHRASE`) |
| `ANLEITUNG.md` | Vollständige Schritt-für-Schritt Einrichtungsanleitung |
| `MIGRATION.md` | Anleitung für Migration von rsync auf Borg |

## Erste Schritte

Alle Schritte sind in [ANLEITUNG.md](ANLEITUNG.md) dokumentiert, gegliedert in:

1. **Backup-Server einrichten** — WireGuard Server, SSH-Keys (append-only), `borg-prune.sh` als Cron-Job
2. **Pro Unraid-Server** — borg Binary installieren, WireGuard Client, `borg-backup.sh` konfigurieren
3. **Disaster Recovery** — Archive auflisten, Dateien wiederherstellen, Schlüssel wiederherstellen
4. **Wartung** — quartalsweise Restore-Tests, Prune-Kontrolle, Speicherplatz-Übersicht

## Lizenz

[MIT](LICENSE)

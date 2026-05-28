#!/bin/bash
# borg-prune.sh — Borg Prune & Wartung für den Offsite-Backup-Server
# Läuft direkt auf dem Ubuntu Backup-Server als Cron-Job.
# Verwendet Admin-SSH-Key (nicht append-only) — direkt auf Repo, kein SSH nötig.

set -uo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# KONFIGURATION — Diese Sektion anpassen
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Prune-Jobs ───────────────────────────────────────────────────────────────
# Format: "repo_pfad" "glob_prefix" keep_daily keep_weekly keep_monthly keep_yearly
prune_jobs=(
  "/repos/unraid1"  "unraid1-appdata-*"    14  8  12  3
  "/repos/unraid1"  "unraid1-databases-*"  30 12  24  5
  "/repos/unraid2"  "unraid2-appdata-*"    14  8  12  3
)

# ─── Speicherplatz-Überwachung ────────────────────────────────────────────────
repos_mount="/repos"                   # Mountpoint der Backup-Festplatte
disk_warn_percent=85                   # Warnung wenn Belegung diesen Wert übersteigt

# ─── Uptime Kuma Webhook für Disk-Warnung (leer = deaktiviert) ────────────────
disk_warn_url=""

# ─── Logging ──────────────────────────────────────────────────────────────────
log_dir="/var/log/borg-prune"
log_retention_days=90                  # Prune-Logs länger aufheben als Backup-Logs

# ─── Secrets ──────────────────────────────────────────────────────────────────
env_file="/etc/borg-prune/.env"        # enthält BORG_PASSPHRASE

# ═══════════════════════════════════════════════════════════════════════════════
# SCRIPT-LOGIK — Nichts unterhalb ändern
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_START=$(date +%s)
overall_status=0

# ─── Logging-Setup ────────────────────────────────────────────────────────────
mkdir -p "$log_dir"
log_file="${log_dir}/borg-prune-$(date +%Y-%m-%d).log"

_log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a "$log_file"
}

# ─── .env laden & Passphrase setzen ──────────────────────────────────────────
if [[ ! -f "$env_file" ]]; then
    _log "ERROR" ".env nicht gefunden: ${env_file}"
    exit 1
fi
# shellcheck source=/dev/null
source "$env_file"

if [[ -z "${BORG_PASSPHRASE:-}" ]]; then
    _log "ERROR" "BORG_PASSPHRASE nicht gesetzt in ${env_file}"
    exit 1
fi
export BORG_PASSPHRASE

# ─── Borg-Binary prüfen ───────────────────────────────────────────────────────
if ! command -v borg &>/dev/null; then
    _log "ERROR" "'borg' nicht gefunden! apt install borgbackup"
    exit 1
fi

_log "INFO" "Borg Prune gestartet (borg $(borg --version 2>/dev/null | awk '{print $2}'))"

# ─── 1. Speicherplatz prüfen ──────────────────────────────────────────────────
disk_used_percent=$(df --output=pcent "$repos_mount" 2>/dev/null | tail -1 | tr -d ' %')

if [[ -z "$disk_used_percent" ]]; then
    _log "WARN" "Speicherplatz von ${repos_mount} konnte nicht ermittelt werden"
else
    _log "INFO" "Speicherplatz ${repos_mount}: ${disk_used_percent}% belegt"

    if [[ "$disk_used_percent" -ge "$disk_warn_percent" ]]; then
        _log "ERROR" "Speicherplatz kritisch: ${disk_used_percent}% >= ${disk_warn_percent}%"

        if [[ -n "$disk_warn_url" ]]; then
            curl -fsS --max-time 10 \
                "${disk_warn_url}?status=down&msg=Disk+${disk_used_percent}pct" &>/dev/null || true
            _log "INFO" "Disk-Warnung an Uptime Kuma gesendet"
        fi

        _log "ERROR" "Prune abgebrochen — Speicherplatz bereinigen!"
        exit 1
    fi
fi

# ─── 2. Prune, Compact und Info pro Job ───────────────────────────────────────
i=0
while [[ $i -lt ${#prune_jobs[@]} ]]; do
    repo_path="${prune_jobs[$i]}"
    glob_prefix="${prune_jobs[$((i+1))]}"
    keep_daily="${prune_jobs[$((i+2))]}"
    keep_weekly="${prune_jobs[$((i+3))]}"
    keep_monthly="${prune_jobs[$((i+4))]}"
    keep_yearly="${prune_jobs[$((i+5))]}"
    i=$((i+6))

    _log "INFO" "══════════════════════════════════════════════"
    _log "INFO" "Repo: ${repo_path} | Prefix: ${glob_prefix}"

    # Repo-Existenz prüfen
    if [[ ! -d "$repo_path" ]]; then
        _log "WARN" "Repo-Verzeichnis nicht gefunden: ${repo_path} — übersprungen"
        continue
    fi

    if ! borg info "$repo_path" &>/dev/null; then
        _log "WARN" "Kein gültiges Borg-Repo unter ${repo_path} — übersprungen"
        continue
    fi

    # a) borg prune
    _log "INFO" "Prune: daily=${keep_daily} weekly=${keep_weekly} monthly=${keep_monthly} yearly=${keep_yearly}"
    if borg prune \
        --glob-archives "${glob_prefix}" \
        --keep-daily "$keep_daily" \
        --keep-weekly "$keep_weekly" \
        --keep-monthly "$keep_monthly" \
        --keep-yearly "$keep_yearly" \
        --stats \
        --list \
        "$repo_path" 2>>"$log_file"; then
        _log "OK" "Prune erfolgreich: ${glob_prefix}"
    else
        _log "ERROR" "Prune fehlgeschlagen: ${glob_prefix}"
        overall_status=1
    fi

    # b) borg compact
    _log "INFO" "Compact: ${repo_path}"
    if borg compact "$repo_path" 2>>"$log_file"; then
        _log "OK" "Compact erfolgreich: ${repo_path}"
    else
        _log "WARN" "Compact fehlgeschlagen (unkritisch): ${repo_path}"
    fi
    # Compact läuft als root → neu erstellte Dateien gehören root statt borg.
    # SSH-Clients (borg-User) können root-Dateien nicht lesen → Backups schlagen fehl.
    find "$repo_path" -not -user borg -exec chown borg:borg {} + 2>>"$log_file" || true
    _log "INFO" "Ownership-Check abgeschlossen: ${repo_path}"

    # c) borg info (Statistik ins Log)
    _log "INFO" "Statistik für: ${repo_path}"
    borg info "$repo_path" 2>>"$log_file" | tee -a "$log_file" | grep -E 'All archives:|Unique chunks:|Total size:|Deduplication' | while read -r line; do
        _log "INFO" "  $line"
    done

done

# ─── 3. Monatliche Integritätsprüfung ─────────────────────────────────────────
# Läuft nur am 1. des Monats
if [[ "$(date +%d)" -eq 1 ]]; then
    _log "INFO" "══════════════════════════════════════════════"
    _log "INFO" "Monatliche Integritätsprüfung (borg check --repository-only)"

    i=0
    checked_repos=()
    while [[ $i -lt ${#prune_jobs[@]} ]]; do
        repo_path="${prune_jobs[$i]}"
        i=$((i+6))

        # Jedes Repo nur einmal prüfen
        already_checked=0
        for r in "${checked_repos[@]:-}"; do
            [[ "$r" == "$repo_path" ]] && already_checked=1 && break
        done
        [[ "$already_checked" -eq 1 ]] && continue
        checked_repos+=("$repo_path")

        if [[ ! -d "$repo_path" ]]; then
            continue
        fi

        _log "INFO" "Integritätsprüfung: ${repo_path}"
        if borg check --repository-only "$repo_path" 2>>"$log_file"; then
            _log "OK" "Integritätsprüfung erfolgreich: ${repo_path}"
        else
            _log "ERROR" "Integritätsprüfung fehlgeschlagen: ${repo_path}"
            overall_status=1
        fi
    done
fi

# ─── Alte Logs aufräumen ──────────────────────────────────────────────────────
deleted_logs=$(find "$log_dir" -maxdepth 1 -name "*.log" -mtime "+${log_retention_days}" -print -delete 2>/dev/null | wc -l)
[[ "$deleted_logs" -gt 0 ]] && _log "INFO" "Log-Rotation: ${deleted_logs} alte Log(s) gelöscht"

# ─── Gesamtergebnis ───────────────────────────────────────────────────────────
duration=$(( $(date +%s) - SCRIPT_START ))
duration_fmt=$(printf '%02dh %02dm %02ds' $((duration/3600)) $((duration%3600/60)) $((duration%60)))

if [[ "$overall_status" -eq 0 ]]; then
    _log "OK" "Prune abgeschlossen (Laufzeit: ${duration_fmt})"
else
    _log "ERROR" "Prune mit Fehlern abgeschlossen (Laufzeit: ${duration_fmt}) — Logs prüfen!"
    exit 1
fi

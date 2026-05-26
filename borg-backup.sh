#!/bin/bash
# borg-backup.sh — Borg Backup Client für Unraid Main-Server
# Läuft als Cron-Job auf jedem Unraid Main-Server.
# Append-only Push via SSH über WireGuard-VPN zum Offsite-Backup-Server.

set -uo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# KONFIGURATION — Diese Sektion anpassen
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Identität ────────────────────────────────────────────────────────────────
hostname="unraid1"                      # Eindeutiger Name, wird Teil des Archiv-Namens

# ─── WireGuard ────────────────────────────────────────────────────────────────
wireguard_interface="wg0"               # WireGuard-Interface-Name
wireguard_connect=1                     # 1 = Script verbindet/trennt selbst | 0 = immer-on

# ─── Backup-Jobs ──────────────────────────────────────────────────────────────
# Format: "quelle" "ssh://backupserver/repos/hostname" "jobname" [keep_daily keep_weekly keep_monthly keep_yearly]
# Retention-Werte optional — werden aus Defaults übernommen wenn weggelassen
backup_jobs=(
  "/mnt/user/backup/appdata"    "ssh://10.8.0.1/repos/unraid1"  "appdata"    14  8  12  3
  "/mnt/user/backup/databases"  "ssh://10.8.0.1/repos/unraid1"  "databases"  30 12  24  5
)

# ─── Retention Defaults ───────────────────────────────────────────────────────
default_keep_daily=14
default_keep_weekly=8
default_keep_monthly=12
default_keep_yearly=3

# ─── Komprimierung & Performance ──────────────────────────────────────────────
compression="auto,zstd,3"              # Komprimiert nur wenn es hilft
checkpoint_interval=300                # Sekunden zwischen Checkpoints (Resume bei Abbruch)
remote_ratelimit_kbs=0                 # kB/s Upload-Limit (0 = unlimitiert)

# ─── Sicherheitsprüfung ───────────────────────────────────────────────────────
backup_must_contain_files=2            # Job schlägt fehl wenn weniger Dateien vorhanden

# ─── Logging ──────────────────────────────────────────────────────────────────
log_dir="/var/log/borg-backup"
log_retention_days=30

# ─── Healthcheck (Uptime Kuma Push-URL) ───────────────────────────────────────
healthcheck_url=""                     # leer = deaktiviert
                                       # z.B.: https://uptime.example.com/api/push/abc123

# ─── Secrets ──────────────────────────────────────────────────────────────────
env_file="/etc/borg-backup/.env"       # enthält BORG_PASSPHRASE

# ═══════════════════════════════════════════════════════════════════════════════
# SCRIPT-LOGIK — Nichts unterhalb ändern
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_START=$(date +%s)
overall_status=0                       # 0 = alles OK, 1 = mind. ein Job fehlgeschlagen

# ─── Argumente auswerten ──────────────────────────────────────────────────────
arg_dry_run=0
arg_init_only=0
arg_job_filter=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   arg_dry_run=1; shift ;;
        --init-only) arg_init_only=1; shift ;;
        --job)       arg_job_filter="$2"; shift 2 ;;
        --help)
            echo "Verwendung: $(basename "$0") [--dry-run] [--init-only] [--job NAME] [--help]"
            echo ""
            echo "  --dry-run      Simulationsmodus, keine Änderungen"
            echo "  --init-only    Nur Repo initialisieren, kein Backup"
            echo "  --job NAME     Nur einen bestimmten Job ausführen"
            echo "  --help         Diese Hilfe anzeigen"
            exit 0
            ;;
        *) echo "Unbekanntes Argument: $1"; exit 1 ;;
    esac
done

# ─── Logging-Setup ────────────────────────────────────────────────────────────
mkdir -p "$log_dir"
main_log="${log_dir}/${hostname}-$(date +%Y-%m-%d).log"

_log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a "$main_log"
}

_log_job() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a "$main_log" >> "$job_log"
}

# ─── Unraid-Notification ──────────────────────────────────────────────────────
_notify_unraid() {
    local severity="$1"   # normal | warning | alert
    local subject="$2"
    local description="$3"
    local notify_script="/usr/local/emhttp/webGui/scripts/notify"
    if [[ -x "$notify_script" ]]; then
        "$notify_script" -e "Borg Backup" -s "$subject" -d "$description" -i "$severity"
    fi
}

# ─── Cleanup / Trap ───────────────────────────────────────────────────────────
_cleanup() {
    if [[ "$wireguard_connect" -eq 1 ]]; then
        if ip link show "$wireguard_interface" &>/dev/null; then
            _log "INFO" "WireGuard trennen: ${wireguard_interface}"
            wg-quick down "$wireguard_interface" 2>>"$main_log" || true
        fi
    fi
}
trap _cleanup EXIT

# ─── .env laden ───────────────────────────────────────────────────────────────
if [[ ! -f "$env_file" ]]; then
    _log "ERROR" ".env nicht gefunden: ${env_file}"
    _notify_unraid "alert" "Borg Backup fehlgeschlagen" ".env fehlt: ${env_file}"
    exit 1
fi
# shellcheck source=/dev/null
source "$env_file"

if [[ -z "${BORG_PASSPHRASE:-}" ]]; then
    _log "ERROR" "BORG_PASSPHRASE nicht gesetzt in ${env_file}"
    _notify_unraid "alert" "Borg Backup fehlgeschlagen" "BORG_PASSPHRASE fehlt in ${env_file}"
    exit 1
fi
export BORG_PASSPHRASE

# ─── Borg-Binäry prüfen ───────────────────────────────────────────────────────
if ! command -v borg &>/dev/null; then
    _log "ERROR" "'borg' nicht gefunden! Installation: apt install borgbackup"
    _notify_unraid "alert" "Borg Backup fehlgeschlagen" "borgbackup nicht installiert"
    exit 1
fi

_log "INFO" "Borg Backup gestartet auf ${hostname} (borg $(borg --version 2>/dev/null | awk '{print $2}'))"
[[ "$arg_dry_run" -eq 1 ]] && _log "INFO" "DRY-RUN Modus aktiv — keine Änderungen"

# ─── WireGuard verbinden ──────────────────────────────────────────────────────
if [[ "$wireguard_connect" -eq 1 ]]; then
    _log "INFO" "WireGuard verbinden: ${wireguard_interface}"
    if ! wg-quick up "$wireguard_interface" 2>>"$main_log"; then
        _log "ERROR" "WireGuard konnte nicht gestartet werden"
        _notify_unraid "alert" "Borg Backup fehlgeschlagen" "WireGuard ${wireguard_interface} Start fehlgeschlagen"
        exit 1
    fi
    _log "INFO" "WireGuard verbunden"
fi

# ─── Standard-Excludes ────────────────────────────────────────────────────────
default_excludes=(
    "--exclude=**/\$RECYCLE.BIN"
    "--exclude=**/.Trash*"
    "--exclude=**/tmp/"
    "--exclude=**/temp/"
    "--exclude=**/__pycache__/"
    "--exclude=**/.DS_Store"
    "--exclude=**/*.tmp"
)

# ─── Jobs verarbeiten ─────────────────────────────────────────────────────────
job_count=$(( ${#backup_jobs[@]} / 7 ))
job_errors=()

# Stride: jeder Job belegt 7 Felder (quelle repo name daily weekly monthly yearly)
# Optionale Retention: wenn nur 3 Felder (quelle repo name), Defaults verwenden
# Tatsächlich: Format ist variabel — wir parsen manuell

i=0
while [[ $i -lt ${#backup_jobs[@]} ]]; do
    job_source="${backup_jobs[$i]}"
    job_repo="${backup_jobs[$((i+1))]}"
    job_name="${backup_jobs[$((i+2))]}"

    # Retention aus Array oder Defaults
    if [[ $((i+6)) -lt ${#backup_jobs[@]} ]] && [[ "${backup_jobs[$((i+3))]}" =~ ^[0-9]+$ ]]; then
        keep_daily="${backup_jobs[$((i+3))]}"
        keep_weekly="${backup_jobs[$((i+4))]}"
        keep_monthly="${backup_jobs[$((i+5))]}"
        keep_yearly="${backup_jobs[$((i+6))]}"
        i=$((i+7))
    else
        keep_daily="$default_keep_daily"
        keep_weekly="$default_keep_weekly"
        keep_monthly="$default_keep_monthly"
        keep_yearly="$default_keep_yearly"
        i=$((i+3))
    fi

    # Job-Filter: wenn --job gesetzt, nur diesen Job ausführen
    if [[ -n "$arg_job_filter" && "$job_name" != "$arg_job_filter" ]]; then
        continue
    fi

    job_log="${log_dir}/${hostname}-${job_name}-$(date +%Y-%m-%d).log"
    _log_job "INFO" "══════════════════════════════════════════════"
    _log_job "INFO" "Job: ${job_name} | Quelle: ${job_source} | Repo: ${job_repo}"

    # Quelle prüfen
    if [[ ! -d "$job_source" ]]; then
        _log_job "ERROR" "Quellverzeichnis nicht vorhanden: ${job_source}"
        job_errors+=("$job_name")
        overall_status=1
        continue
    fi

    # Dateianzahl-Prüfung
    file_count=$(find "$job_source" -maxdepth 3 -type f 2>/dev/null | wc -l)
    if [[ "$file_count" -lt "$backup_must_contain_files" ]]; then
        _log_job "ERROR" "Zu wenige Dateien in ${job_source}: ${file_count} (Minimum: ${backup_must_contain_files})"
        job_errors+=("$job_name")
        overall_status=1
        continue
    fi

    # Repo initialisieren falls nicht vorhanden
    if ! borg info "$job_repo" &>/dev/null; then
        _log_job "INFO" "Repo existiert nicht — initialisiere: ${job_repo}"
        if [[ "$arg_dry_run" -eq 0 ]]; then
            if ! borg init --encryption=repokey-blake2 "$job_repo" 2>>"$job_log"; then
                _log_job "ERROR" "Repo-Initialisierung fehlgeschlagen: ${job_repo}"
                job_errors+=("$job_name")
                overall_status=1
                continue
            fi
            _log_job "OK" "Repo initialisiert: ${job_repo}"
            _log_job "WARN" "WICHTIG: Borg-Key exportieren und sicher aufbewahren!"
            _log_job "WARN" "  borg key export ${job_repo} /tmp/${hostname}.borg.key"
            _log_job "WARN" "  Inhalt ausdrucken → Datei sofort löschen!"
            _notify_unraid "warning" "Borg Repo initialisiert" "Job ${job_name}: Key exportieren und ausdrucken! ${job_repo}"
        else
            _log_job "INFO" "[DRY-RUN] Würde Repo initialisieren: ${job_repo}"
        fi
    fi

    [[ "$arg_init_only" -eq 1 ]] && continue

    # Archiv-Namen bestimmen (Resume-Logik)
    archive_datetime=$(date +%Y-%m-%dT%H:%M)
    archive_name="${hostname}-${job_name}-${archive_datetime}"

    # Prüfen ob ein unterbrochenes Checkpoint-Archiv existiert
    checkpoint_archive=$(borg list "$job_repo" --glob-archives "${hostname}-${job_name}-*.checkpoint" \
        --format '{archive}{NL}' 2>/dev/null | tail -1)

    if [[ -n "$checkpoint_archive" ]]; then
        # Checkpoint gefunden: gleichen Basis-Namen ohne .checkpoint verwenden → Resume
        archive_name="${checkpoint_archive%.checkpoint}"
        _log_job "INFO" "Checkpoint gefunden — Resume: ${archive_name}"
    else
        _log_job "INFO" "Neues Archiv: ${archive_name}"
    fi

    # borg create Argumente zusammenbauen
    borg_create_args=(
        create
        --verbose
        --stats
        --show-rc
        --compression "$compression"
        --checkpoint-interval "$checkpoint_interval"
    )

    [[ "$remote_ratelimit_kbs" -gt 0 ]] && borg_create_args+=(--remote-ratelimit "$remote_ratelimit_kbs")
    [[ "$arg_dry_run" -eq 1 ]] && borg_create_args+=(--dry-run)

    borg_create_args+=("${default_excludes[@]}")
    borg_create_args+=("${job_repo}::${archive_name}")
    borg_create_args+=("$job_source")

    # borg create ausführen
    _log_job "INFO" "Starte borg create..."
    borg "${borg_create_args[@]}" 2>>"$job_log"
    borg_rc=$?

    case "$borg_rc" in
        0)
            _log_job "OK" "Backup erfolgreich: ${archive_name}"
            ;;
        1)
            _log_job "WARN" "Backup mit Warnungen abgeschlossen (RC=1, z.B. vanished files): ${archive_name}"
            ;;
        *)
            _log_job "ERROR" "Backup fehlgeschlagen (RC=${borg_rc}): ${archive_name}"
            job_errors+=("$job_name")
            overall_status=1
            continue
            ;;
    esac

done

# ─── Alte Logs aufräumen ──────────────────────────────────────────────────────
deleted_logs=$(find "$log_dir" -maxdepth 1 -name "*.log" -mtime "+${log_retention_days}" -print -delete 2>/dev/null | wc -l)
[[ "$deleted_logs" -gt 0 ]] && _log "INFO" "Log-Rotation: ${deleted_logs} alte Log(s) gelöscht"

# ─── Gesamtergebnis ───────────────────────────────────────────────────────────
duration=$(( $(date +%s) - SCRIPT_START ))
duration_fmt=$(printf '%02dh %02dm %02ds' $((duration/3600)) $((duration%3600/60)) $((duration%60)))

if [[ "$overall_status" -eq 0 ]]; then
    _log "OK" "Alle Jobs erfolgreich abgeschlossen (Laufzeit: ${duration_fmt})"

    if [[ -n "$healthcheck_url" ]]; then
        if curl -fsS --max-time 10 "${healthcheck_url}" &>/dev/null; then
            _log "INFO" "Uptime Kuma Ping gesendet"
        else
            _log "WARN" "Uptime Kuma Ping fehlgeschlagen (${healthcheck_url})"
        fi
    fi
else
    failed_list=$(IFS=', '; echo "${job_errors[*]}")
    _log "ERROR" "Backup fehlgeschlagen — Fehlerhafte Jobs: ${failed_list} (Laufzeit: ${duration_fmt})"
    _notify_unraid "alert" "Borg Backup fehlgeschlagen" "Fehlerhafte Jobs: ${failed_list}"
    exit 1
fi

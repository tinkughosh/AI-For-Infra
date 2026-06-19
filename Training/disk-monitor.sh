#!/bin/bash
set -euo pipefail

# =============================================================================
# disk-monitor.sh — Disk Usage Monitor & Log Archiver
# Ubuntu 22.04 | Author: Senior Storage Engineer
# Usage:
#   sudo ./disk-monitor.sh               # one-time run
#   sudo ./disk-monitor.sh --daemon      # daemon mode (every 5 minutes)
#   sudo ./disk-monitor.sh --dry-run     # dry-run one-time
#   sudo ./disk-monitor.sh --daemon --dry-run  # dry-run daemon
#   sudo ./disk-monitor.sh --rollback    # restore archived files
# =============================================================================

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly MONITOR_PATH="/"
readonly WARN_THRESHOLD=80
readonly ALERT_THRESHOLD=90
readonly APP_LOG_DIR="/var/log/app"
readonly ARCHIVE_DIR="/var/log/app/archive"
readonly MONITOR_LOG="/var/log/disk-monitor.log"
readonly LOCK_FILE="/var/run/disk-monitor.lock"
readonly LOG_AGE_DAYS=7
readonly INTERVAL_SECONDS=300   # 5 minutes
readonly SCRIPT_NAME="$(basename "$0")"
readonly MIN_ARCHIVE_FREE_MB=100  # Minimum free space required in archive dir (MB)

# -----------------------------------------------------------------------------
# Flags
# -----------------------------------------------------------------------------
DAEMON_MODE=false
DRY_RUN=false
ROLLBACK_MODE=false
RESILIENCE_FILL=false
RESILIENCE_CLEANUP=false

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --daemon)    DAEMON_MODE=true ;;
    --dry-run)   DRY_RUN=true ;;
    --rollback)  ROLLBACK_MODE=true ;;
    --resilience-fill)    RESILIENCE_FILL=true ;;
    --resilience-cleanup) RESILIENCE_CLEANUP=true ;;
    --help|-h)
      echo "Usage: sudo $SCRIPT_NAME [--daemon] [--dry-run] [--rollback] [--resilience-fill] [--resilience-cleanup]"
      echo ""
      echo "  --daemon             Run continuously, checking every ${INTERVAL_SECONDS}s"
      echo "  --dry-run            Show what would be compressed without doing it"
      echo "  --rollback           Decompress and restore archived files back to ${APP_LOG_DIR}"
      echo "  --resilience-fill    RESILIENCE TEST: fill disk to ~95% via fallocate (Scenario C trigger)"
      echo "  --resilience-cleanup RESILIENCE TEST: remove /tmp/diskfill.img, validate recovery (Scenario C recovery)"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg. Use --help for usage." >&2
      exit 1
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------
log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  local entry="[$timestamp] [$level] $message"

  # Write to log file (requires root / sudo)
  echo "$entry" | sudo tee -a "$MONITOR_LOG" > /dev/null
  # Also echo to stdout
  echo "$entry"
}

log_info()  { log "INFO " "$@"; }
log_warn()  { log "WARN " "$@"; }
log_alert() { log "ALERT" "$@"; }
log_error() { log "ERROR" "$@"; }
log_dry()   { log "DRYRN" "$@"; }

# -----------------------------------------------------------------------------
# Idempotency — prevent duplicate instances
# -----------------------------------------------------------------------------
check_already_running() {
  if [[ -f "$LOCK_FILE" ]]; then
    local existing_pid
    existing_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo '')"

    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      echo "[$SCRIPT_NAME] Already running with PID $existing_pid. Exiting." >&2
      exit 0
    else
      # Stale lock file — clean it up
      echo "[$SCRIPT_NAME] Removing stale lock file (PID $existing_pid no longer active)."
      sudo rm -f "$LOCK_FILE"
    fi
  fi
}

acquire_lock() {
  echo $$ | sudo tee "$LOCK_FILE" > /dev/null
}

release_lock() {
  sudo rm -f "$LOCK_FILE"
}

# Ensure lock is released on exit
trap 'release_lock' EXIT INT TERM

# -----------------------------------------------------------------------------
# Get disk usage percentage for a given path
# -----------------------------------------------------------------------------
get_disk_usage() {
  local path="$1"
  df -h "$path" | awk 'NR==2 {gsub(/%/, "", $5); print $5}'
}

# -----------------------------------------------------------------------------
# Verify archive directory exists and has sufficient free space
# -----------------------------------------------------------------------------
verify_archive_dir() {
  if [[ ! -d "$ARCHIVE_DIR" ]]; then
    log_info "Archive directory $ARCHIVE_DIR does not exist. Creating..."
    if [[ "$DRY_RUN" == true ]]; then
      log_dry "Would create archive directory: $ARCHIVE_DIR"
      return 0
    fi
    sudo mkdir -p "$ARCHIVE_DIR"
    sudo chmod 750 "$ARCHIVE_DIR"
    log_info "Created archive directory: $ARCHIVE_DIR"
  fi

  # Check free space on archive directory's filesystem
  local free_mb
  free_mb=$(df -BM "$ARCHIVE_DIR" | awk 'NR==2 {gsub(/M/, "", $4); print $4}')

  if (( free_mb < MIN_ARCHIVE_FREE_MB )); then
    log_error "Insufficient space in archive filesystem: ${free_mb}MB free (minimum: ${MIN_ARCHIVE_FREE_MB}MB). Skipping archival."
    return 1
  fi

  log_info "Archive directory OK. Free space: ${free_mb}MB"
  return 0
}

# -----------------------------------------------------------------------------
# Find, compress, and move old log files
# -----------------------------------------------------------------------------
archive_old_logs() {
  local usage="$1"

  log_info "Disk usage at ${usage}%. Scanning for log files older than ${LOG_AGE_DAYS} days in ${APP_LOG_DIR}..."

  # Find log files (non-compressed) older than LOG_AGE_DAYS days
  # Exclude the archive subdirectory and already-compressed files
  local files=()
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(sudo find "$APP_LOG_DIR" \
    -maxdepth 1 \
    -type f \
    -name "*.log" \
    -not -name "*.gz" \
    -mtime +"$LOG_AGE_DAYS" \
    -print0 2>/dev/null)

  if [[ ${#files[@]} -eq 0 ]]; then
    log_info "No log files older than ${LOG_AGE_DAYS} days found. Nothing to archive."
    return 0
  fi

  log_info "Found ${#files[@]} file(s) to archive."

  # Verify archive directory and space before proceeding
  if ! verify_archive_dir; then
    return 1
  fi

  local archived_count=0
  local skipped_count=0
  local summary_files=()

  for file in "${files[@]}"; do
    local filename
    filename="$(basename "$file")"
    local compressed_name="${filename}.gz"
    local dest="${ARCHIVE_DIR}/${compressed_name}"

    # Idempotency: skip if already archived
    if [[ -f "$dest" ]]; then
      log_info "Already archived, skipping: $compressed_name"
      (( skipped_count++ )) || true
      continue
    fi

    if [[ "$DRY_RUN" == true ]]; then
      log_dry "Would compress: $file -> $dest"
      summary_files+=("$filename")
      (( archived_count++ )) || true
      continue
    fi

    # Compress to archive directory (never deletes original until confirmed)
    log_info "Compressing: $file"
    sudo gzip -c "$file" | sudo tee "$dest" > /dev/null

    # Verify compressed file was created and is non-empty
    if [[ ! -s "$dest" ]]; then
      log_error "Compressed file $dest is empty or missing. Skipping removal of original."
      sudo rm -f "$dest"
      (( skipped_count++ )) || true
      continue
    fi

    # Move original to archive (rename — no deletion)
    sudo mv "$file" "${ARCHIVE_DIR}/${filename}.archived"

    log_info "Archived: $filename -> $dest (original kept as ${filename}.archived)"
    summary_files+=("$filename")
    (( archived_count++ )) || true
  done

  # Write summary to log
  local summary="Archive run complete. Processed: ${archived_count}, Skipped: ${skipped_count}."
  if [[ ${#summary_files[@]} -gt 0 ]]; then
    summary+=" Files: $(IFS=', '; echo "${summary_files[*]}")"
  fi
  log_info "$summary"
}

# -----------------------------------------------------------------------------
# rollback(): decompress and restore archived files back to APP_LOG_DIR
# -----------------------------------------------------------------------------
rollback() {
  log_info "=== ROLLBACK STARTED ==="
  log_info "Restoring compressed files from $ARCHIVE_DIR to $APP_LOG_DIR ..."

  if [[ ! -d "$ARCHIVE_DIR" ]]; then
    log_warn "Archive directory $ARCHIVE_DIR does not exist. Nothing to rollback."
    return 0
  fi

  local restored_count=0
  local failed_count=0

  # Restore .gz compressed files
  while IFS= read -r -d '' gz_file; do
    local filename
    filename="$(basename "$gz_file" .gz)"
    local dest="${APP_LOG_DIR}/${filename}"

    if [[ "$DRY_RUN" == true ]]; then
      log_dry "Would decompress: $gz_file -> $dest"
      (( restored_count++ )) || true
      continue
    fi

    # Do not overwrite existing file in APP_LOG_DIR
    if [[ -f "$dest" ]]; then
      log_warn "Target file already exists, skipping: $dest"
      (( failed_count++ )) || true
      continue
    fi

    log_info "Decompressing: $gz_file -> $dest"
    if sudo gunzip -c "$gz_file" | sudo tee "$dest" > /dev/null; then
      # Remove the .gz file from archive after successful restore
      sudo rm -f "$gz_file"
      log_info "Restored: $filename"
      (( restored_count++ )) || true
    else
      log_error "Failed to decompress: $gz_file"
      sudo rm -f "$dest"   # clean up partial file
      (( failed_count++ )) || true
    fi
  done < <(sudo find "$ARCHIVE_DIR" -maxdepth 1 -type f -name "*.gz" -print0 2>/dev/null)

  # Restore .archived originals (files moved with .archived extension)
  while IFS= read -r -d '' arch_file; do
    local filename
    filename="$(basename "$arch_file" .archived)"
    local dest="${APP_LOG_DIR}/${filename}"

    if [[ "$DRY_RUN" == true ]]; then
      log_dry "Would restore original: $arch_file -> $dest"
      (( restored_count++ )) || true
      continue
    fi

    if [[ -f "$dest" ]]; then
      log_warn "Target already exists, skipping original restore: $dest"
      (( failed_count++ )) || true
      continue
    fi

    log_info "Restoring original: $arch_file -> $dest"
    if sudo mv "$arch_file" "$dest"; then
      log_info "Restored original: $filename"
      (( restored_count++ )) || true
    else
      log_error "Failed to restore: $arch_file"
      (( failed_count++ )) || true
    fi
  done < <(sudo find "$ARCHIVE_DIR" -maxdepth 1 -type f -name "*.archived" -print0 2>/dev/null)

  log_info "=== ROLLBACK COMPLETE === Restored: ${restored_count}, Failed: ${failed_count}."
}

# -----------------------------------------------------------------------------
# resilience_fill(): Resilience Scenario C trigger — disk exhaustion.
# Uses fallocate to fill the filesystem to ~95%, leaving 200 MB free.
# Safe: fallocate is instantaneous with no real I/O. Reversed by --resilience-cleanup.
# Go/No-Go: aborts if disk usage >= 60% or /tmp/diskfill.img already exists.
# -----------------------------------------------------------------------------
resilience_fill() {
  log_info "=== RESILIENCE FILL START: Scenario C — Disk Exhaustion Test ==="

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "Would: verify usage < 60%, fallocate fill (leaving 200 MB), create /tmp/diskfill.img"
    log_dry "Reversal command: sudo $SCRIPT_NAME --resilience-cleanup"
    return 0
  fi

  # Go/No-Go: current usage must be < 60%
  local current_pct
  current_pct="$(get_disk_usage "$MONITOR_PATH")"
  if (( current_pct >= 60 )); then
    log_error "GO/NO-GO ABORT: disk usage is ${current_pct}% — must be < 60% before fill test. Free space first."
    exit 1
  fi
  log_info "Go/No-Go PASS: disk usage = ${current_pct}% — safe to proceed."

  # Idempotency: abort if a previous fill file was not cleaned up
  if [[ -f /tmp/diskfill.img ]]; then
    log_error "ABORT: /tmp/diskfill.img already exists — run --resilience-cleanup before re-triggering."
    exit 1
  fi

  # Calculate fill size: leave exactly 200 MB (204800 KB) free
  local avail_kb fill_kb
  avail_kb="$(df / | awk 'NR==2 {print $4}')"
  fill_kb=$(( avail_kb - 204800 ))
  if (( fill_kb <= 0 )); then
    log_error "ABORT: only ${avail_kb} KB available — insufficient headroom for a safe fill test."
    exit 1
  fi

  log_info "Allocating ${fill_kb} KB via fallocate (200 MB reserve)..."
  sudo fallocate -l "${fill_kb}K" /tmp/diskfill.img
  sudo chmod 600 /tmp/diskfill.img

  local post_pct
  post_pct="$(get_disk_usage "$MONITOR_PATH")"
  log_info "POST-FILL: disk usage = ${post_pct}%"

  # Confirm write behaviour as a non-root application user would experience
  if touch /tmp/resilience-writetest-$$ 2>/dev/null; then
    log_info "Write test (non-root): filesystem still accepts writes (OS 5% root reservation in effect)."
    rm -f /tmp/resilience-writetest-$$
  else
    log_info "Write test (non-root): ENOSPC confirmed — application writes are failing as expected."
  fi

  log_info "=== RESILIENCE FILL COMPLETE: disk at ${post_pct}% ==="
  log_info "Recovery command: sudo $SCRIPT_NAME --resilience-cleanup"
}

# -----------------------------------------------------------------------------
# resilience_cleanup(): Resilience Scenario C recovery — restore normal disk space.
# Removes /tmp/diskfill.img and confirms write operations succeed afterwards.
# -----------------------------------------------------------------------------
resilience_cleanup() {
  log_info "=== RESILIENCE CLEANUP START: Scenario C — Disk Recovery ==="

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "Would: remove /tmp/diskfill.img, sync, verify usage < 75%, confirm write succeeds"
    return 0
  fi

  if [[ -f /tmp/diskfill.img ]]; then
    log_info "Removing /tmp/diskfill.img..."
    sudo rm -f /tmp/diskfill.img
    sync
    log_info "Fill file removed. Filesystem synced."
  else
    log_warn "CLEANUP: /tmp/diskfill.img not found — fill test may not have run, or was already cleaned."
  fi

  local post_pct
  post_pct="$(get_disk_usage "$MONITOR_PATH")"
  log_info "POST-CLEANUP: disk usage = ${post_pct}%"

  if (( post_pct < 75 )); then
    log_info "VALIDATION PASS: disk usage = ${post_pct}% — below 75% threshold. Recovery confirmed."
  else
    log_warn "VALIDATION WARN: disk usage = ${post_pct}% — still elevated; inspect for other large files."
  fi

  # Confirm filesystem writes work again
  if echo "recovery-$(date +%s)" > /tmp/resilience-validate-$$ 2>/dev/null; then
    log_info "WRITE CHECK PASS: filesystem writes are functioning normally."
    rm -f /tmp/resilience-validate-$$
  else
    log_error "WRITE CHECK FAILED: cannot write to /tmp after removing fill file. Investigate immediately."
    exit 1
  fi

  log_info "=== RESILIENCE CLEANUP COMPLETE ==="
}

# -----------------------------------------------------------------------------
# Single check cycle
# -----------------------------------------------------------------------------
run_check() {
  local usage
  usage="$(get_disk_usage "$MONITOR_PATH")"

  log_info "Disk usage on ${MONITOR_PATH}: ${usage}%"

  if (( usage >= ALERT_THRESHOLD )); then
    log_alert "CRITICAL: Disk usage is at ${usage}% on ${MONITOR_PATH} — exceeds ${ALERT_THRESHOLD}% threshold!"
    # Print prominent alert to stdout
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!! ALERT: Disk usage at ${usage}% — ABOVE ${ALERT_THRESHOLD}% LIMIT !!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
  fi

  if (( usage >= WARN_THRESHOLD )); then
    log_warn "Disk usage at ${usage}% — exceeds ${WARN_THRESHOLD}% threshold. Starting log archival..."
    archive_old_logs "$usage"
  else
    log_info "Disk usage at ${usage}% — below ${WARN_THRESHOLD}% threshold. No action needed."
  fi
}

# -----------------------------------------------------------------------------
# Ensure required directories and log file are accessible
# -----------------------------------------------------------------------------
init() {
  # Ensure APP_LOG_DIR exists
  if [[ ! -d "$APP_LOG_DIR" ]]; then
    log_info "Creating app log directory: $APP_LOG_DIR"
    sudo mkdir -p "$APP_LOG_DIR"
  fi

  # Ensure monitor log file exists
  if [[ ! -f "$MONITOR_LOG" ]]; then
    sudo touch "$MONITOR_LOG"
    sudo chmod 640 "$MONITOR_LOG"
  fi
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
main() {
  # Handle resilience test modes (one-shot operations; no daemon lock needed)
  if [[ "$RESILIENCE_FILL" == true ]]; then
    resilience_fill
    exit 0
  fi

  if [[ "$RESILIENCE_CLEANUP" == true ]]; then
    resilience_cleanup
    exit 0
  fi

  # Handle rollback mode independently (no lock needed for dry-run rollback)
  if [[ "$ROLLBACK_MODE" == true ]]; then
    init
    rollback
    exit 0
  fi

  # Idempotency: ensure only one instance runs
  check_already_running

  # Acquire lock
  acquire_lock

  init

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "=== DRY-RUN MODE: No files will be modified ==="
  fi

  if [[ "$DAEMON_MODE" == true ]]; then
    log_info "=== Starting in DAEMON MODE (interval: ${INTERVAL_SECONDS}s) | PID: $$ ==="
    while true; do
      run_check
      log_info "Sleeping for ${INTERVAL_SECONDS} seconds..."
      sleep "$INTERVAL_SECONDS"
    done
  else
    log_info "=== Starting ONE-TIME RUN | PID: $$ ==="
    run_check
    log_info "=== ONE-TIME RUN COMPLETE ==="
  fi
}

main

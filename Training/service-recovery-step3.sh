#!/usr/bin/env bash
# service-recovery-step3.sh — Payment service incident recovery (Step 3 of runbook)
# Confirms the failure condition is present, captures a thread dump, restarts the
# service, and verifies health. Integrates with resilience Scenario A (CPU exhaustion).
#
# Usage:
#   ./service-recovery-step3.sh                 Full recovery (confirms failure first)
#   ./service-recovery-step3.sh --force         Skip failure-presence prechecks
#   ./service-recovery-step3.sh --stress-cleanup  Scenario A recovery: kill stress-ng, verify, print RTO

set -euo pipefail

SERVICE_NAME="payment-service"
HEALTH_URL="http://localhost:8080/health"
HEAPDUMP_FILE="/tmp/payment-heapdump-$(date +%Y%m%d%H%M).txt"
ROLLBACK_REQUIRED=0
FORCE_MODE=0
STRESS_CLEANUP_MODE=0

# ── Argument parsing ───────────────────────────────────────────────────────────
for arg in "$@"; do
  case "${arg}" in
    --force)
      FORCE_MODE=1
      ;;
    --stress-cleanup)
      STRESS_CLEANUP_MODE=1
      ;;
    --help|-h)
      printf 'Usage: %s [--force] [--stress-cleanup]\n' "$0"
      printf '\n'
      printf '  (no flags)        Full recovery: confirm failure is present, capture thread\n'
      printf '                    dump, restart service, verify health. Use after a real incident.\n'
      printf '  --force           Skip failure-presence prechecks. Use when CPU has already\n'
      printf '                    recovered (e.g. stress-ng self-terminated after timeout) but\n'
      printf '                    the service still needs a restart and health verification.\n'
      printf '  --stress-cleanup  Resilience Scenario A recovery: kill stress-ng, wait for JVM\n'
      printf '                    to stabilise, verify service health, print elapsed RTO.\n'
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "${arg}" >&2
      printf 'Usage: %s [--force] [--stress-cleanup]\n' "$0" >&2
      exit 2
      ;;
  esac
done

fail() {
  local message="$1"
  echo "$message" >&2
  if [[ "$ROLLBACK_REQUIRED" -eq 1 ]]; then
    sudo systemctl stop "$SERVICE_NAME" || true
    echo "Notify #on-call immediately with heap dump location: $HEAPDUMP_FILE" >&2
  fi
  exit 1
}

# ── Confirm CPU failure condition is present ───────────────────────────────────
# Verifies that user CPU is currently > 90%, confirming the incident is still
# active before proceeding with recovery. If CPU has already recovered, use
# --force to skip this check and proceed directly to restart + health verify.
precheck_cpu() {
  local cpu_value
  cpu_value="$(vmstat 1 3 | tail -1 | awk '{print $13}')"
  if ! [[ "$cpu_value" =~ ^[0-9]+$ ]]; then
    fail "CPU pre-check returned a non-numeric value: $cpu_value"
  fi
  if (( cpu_value <= 90 )); then
    fail "CPU pre-check: user CPU = ${cpu_value}% — not above 90%; incident may have resolved. Use --force to override."
  fi
}

# ── Confirm service restart loop is active ────────────────────────────────────
# Verifies the service has crashed and restarted >= 2 times in the last 10
# minutes, establishing that a real incident is in progress. Skipped with
# --force when the service is unhealthy but hasn't entered a restart loop yet.
precheck_restarts() {
  local restart_count
  restart_count="$(journalctl -u "$SERVICE_NAME" --since '10 min ago' | grep -c 'Started')"
  if ! [[ "$restart_count" =~ ^[0-9]+$ ]]; then
    fail "Restart-count pre-check returned a non-numeric value: $restart_count"
  fi
  if (( restart_count < 2 )); then
    fail "Restart-count pre-check: only ${restart_count} restart(s) in last 10 min (need >= 2). Use --force to override."
  fi
}

precheck_change_window() {
  echo "Check the #ops-changes Slack channel for any active change window."
  read -r -p "Type no-active-window to continue: " confirmation
  if [[ "$confirmation" != "no-active-window" ]]; then
    fail "Change-window pre-check not confirmed"
  fi
}

capture_heap_dump() {
  local pids=()
  mapfile -t pids < <(pgrep -f "$SERVICE_NAME")
  if (( ${#pids[@]} == 0 )); then
    fail "No running $SERVICE_NAME process found for heap dump capture"
  fi
  jstack "${pids[@]}" > "$HEAPDUMP_FILE"
}

restart_service() {
  ROLLBACK_REQUIRED=1
  if ! sudo systemctl restart "$SERVICE_NAME"; then
    fail "Restart command failed"
  fi
}

verify_health() {
  local health_status
  if ! health_status="$(curl -sf "$HEALTH_URL" | jq -r '.status')"; then
    fail "Unable to read health status"
  fi
  if [[ "$health_status" != "UP" ]]; then
    fail "Health check failed after restart: $health_status"
  fi
}

# ── Resilience test Scenario A recovery ───────────────────────────────────────
# Kills active stress-ng processes, waits for JVM GC to stabilise, then
# verifies the payment service is healthy. Prints elapsed RTO.
run_stress_cleanup() {
  local rto_start
  rto_start="$(date +%s)"
  printf '[INFO] Scenario A recovery: terminating stress-ng processes...\n'
  if pgrep -x stress-ng > /dev/null 2>&1; then
    sudo pkill -9 stress-ng
    printf '[INFO] stress-ng terminated.\n'
  else
    printf '[INFO] No stress-ng processes found — may have already self-terminated.\n'
  fi
  printf '[INFO] Allowing 15 s for JVM GC pressure to stabilise...\n'
  sleep 15
  verify_health
  local elapsed=$(( $(date +%s) - rto_start ))
  printf '[RTO] Scenario A (stress-cleanup) recovery time: %d s  |  target: < 120 s\n' "${elapsed}"
}

main() {
  local rto_start
  rto_start="$(date +%s)"

  # Resilience test Scenario A recovery mode — skip incident prechecks
  if [[ "${STRESS_CLEANUP_MODE}" -eq 1 ]]; then
    run_stress_cleanup
    return 0
  fi

  # Confirm the failure condition is present before running recovery sequence
  if [[ "${FORCE_MODE}" -eq 0 ]]; then
    precheck_cpu
    precheck_restarts
  else
    printf '[WARN] --force active: skipping failure-presence prechecks.\n'
  fi

  precheck_change_window
  capture_heap_dump
  restart_service
  sleep 30
  verify_health
  set +o pipefail
  systemctl status "$SERVICE_NAME" | head -3
  set -o pipefail

  local elapsed=$(( $(date +%s) - rto_start ))
  printf '[RTO] Full service recovery time: %d s  |  target: < 180 s\n' "${elapsed}"
}

main "$@"
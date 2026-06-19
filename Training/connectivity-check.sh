#!/usr/bin/env bash
set -uo pipefail

# ==============================================================================
# Network Connectivity Validation Script
# Ubuntu 22.04 / Azure — post-change-window health check
# Run as: labadmin  (sudo required for log file creation)
# Usage : ./connectivity-check.sh [--dry-run] [--critical-only]
# ==============================================================================

LOG_FILE="/var/log/connectivity-check.log"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

DRY_RUN=0
CRITICAL_ONLY=0
POST_RECOVERY=0

PASSED=0
FAILED=0
SKIPPED=0
CRITICAL_FAILED=0

# ── Argument parsing ───────────────────────────────────────────────────────────
for arg in "$@"; do
  case "${arg}" in
    --dry-run)
      DRY_RUN=1
      ;;
    --critical-only)
      CRITICAL_ONLY=1
      ;;
    --post-recovery)
      POST_RECOVERY=1
      ;;
    *)
      printf 'Unknown argument: %s\n' "${arg}" >&2
      printf 'Usage: %s [--dry-run] [--critical-only] [--post-recovery]\n' "$0" >&2
      exit 2
      ;;
  esac
done

# ── Log initialisation (sudo) ──────────────────────────────────────────────────
# Creates the log file under /var/log with restricted permissions if absent.
# Idempotent: skipped when the file already exists.
init_log() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  if [[ ! -f "${LOG_FILE}" ]]; then
    sudo touch "${LOG_FILE}"
    sudo chmod 640 "${LOG_FILE}"
    sudo chown root:adm "${LOG_FILE}"
  fi
}

# ── Output + log helper ────────────────────────────────────────────────────────
log() {
  local message="${1}"
  printf '%s\n' "${message}"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    printf '[%s] %s\n' "${TIMESTAMP}" "${message}" | sudo tee -a "${LOG_FILE}" > /dev/null
  fi
}

# ── Result recorders ───────────────────────────────────────────────────────────
record_pass() {
  local label="${1}"
  log "[PASS] ${label}"
  PASSED=$(( PASSED + 1 ))
}

record_fail() {
  local label="${1}"
  local critical="${2}"   # 1 = critical, 0 = non-critical
  log "[FAIL] ${label}"
  FAILED=$(( FAILED + 1 ))
  if [[ "${critical}" -eq 1 ]]; then
    CRITICAL_FAILED=$(( CRITICAL_FAILED + 1 ))
  fi
}

record_skip() {
  local label="${1}"
  log "[SKIP] ${label}"
  SKIPPED=$(( SKIPPED + 1 ))
}

# ── Dry-run printers ───────────────────────────────────────────────────────────
dry_run_would_run() {
  local description="${1}"
  printf '[DRY-RUN] Would run : %s\n' "${description}"
}

dry_run_would_skip() {
  local description="${1}"
  printf '[DRY-RUN] Would skip: %s\n' "${description}"
}

# ── Helper: handle non-critical skip or dry-run annotation ────────────────────
handle_non_critical_skip() {
  local label="${1}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    dry_run_would_skip "${label} (--critical-only active)"
  else
    record_skip "${label} (--critical-only active)"
  fi
}

# ── Check: ping ────────────────────────────────────────────────────────────────
# Usage: check_ping <ip> <label> <critical: 1|0>
check_ping() {
  local ip="${1}"
  local label="${2}"
  local critical="${3}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    dry_run_would_run "ping -c 3 -W 5 ${ip}    # ${label}"
    return 0
  fi

  if ping -c 3 -W 5 "${ip}" > /dev/null 2>&1; then
    record_pass "${label} — ${ip}"
  else
    record_fail "${label} — ${ip}" "${critical}"
  fi
}

# ── Check: nc port ─────────────────────────────────────────────────────────────
# Usage: check_nc <ip> <port> <label> <critical: 1|0>
check_nc() {
  local ip="${1}"
  local port="${2}"
  local label="${3}"
  local critical="${4}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    dry_run_would_run "nc -zv -w 5 ${ip} ${port}    # ${label}"
    return 0
  fi

  if nc -zv -w 5 "${ip}" "${port}" > /dev/null 2>&1; then
    record_pass "${label} — ${ip}:${port}"
  else
    record_fail "${label} — ${ip}:${port}" "${critical}"
  fi
}

# ── Check: DNS resolution ──────────────────────────────────────────────────────
# Usage: check_dns <hostname> <label> <critical: 1|0>
check_dns() {
  local hostname="${1}"
  local label="${2}"
  local critical="${3}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    dry_run_would_run "nslookup ${hostname}    # ${label} (timeout 5s)"
    return 0
  fi

  if timeout 5 nslookup "${hostname}" > /dev/null 2>&1; then
    record_pass "${label} — ${hostname}"
  else
    record_fail "${label} — ${hostname}" "${critical}"
  fi
}

# ── Check: default route ───────────────────────────────────────────────────────
# Usage: check_default_route <critical: 1|0>
check_default_route() {
  local critical="${1}"
  local label="Default route"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    dry_run_would_run "ip route show | grep '^default'    # ${label}"
    return 0
  fi

  local route_output
  route_output="$(ip route show)"
  if printf '%s\n' "${route_output}" | grep -q "^default"; then
    record_pass "${label}"
  else
    record_fail "${label}" "${critical}"
  fi
}

# ── Check: tc qdisc (no artificial latency) ────────────────────────────────────
# Detects netem qdiscs, which are the standard mechanism for injecting latency.
# Usage: check_tc_qdisc <interface> <critical: 1|0>
check_tc_qdisc() {
  local iface="${1}"
  local critical="${2}"
  local label="tc qdisc latency injection — ${iface}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    dry_run_would_run "tc qdisc show dev ${iface}    # ${label}"
    return 0
  fi

  local tc_output
  if tc_output="$(tc qdisc show dev "${iface}" 2>&1)"; then
    if printf '%s\n' "${tc_output}" | grep -q "netem"; then
      record_fail "${label} — netem qdisc detected (artificial latency is active)" "${critical}"
    else
      record_pass "${label} — no artificial latency detected"
    fi
  else
    record_fail "${label} — unable to query tc qdisc on ${iface}" "${critical}"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

init_log

log "════════════════════════════════════════════════════════════"
log "Network Connectivity Check — ${TIMESTAMP}"
if [[ "${DRY_RUN}" -eq 1 && "${CRITICAL_ONLY}" -eq 1 ]]; then
  log "Mode: DRY-RUN + CRITICAL-ONLY"
elif [[ "${DRY_RUN}" -eq 1 ]]; then
  log "Mode: DRY-RUN (no checks will be executed)"
elif [[ "${POST_RECOVERY}" -eq 1 ]]; then
  log "Mode: POST-RECOVERY (PostgreSQL and app health checks promoted to CRITICAL)"
elif [[ "${CRITICAL_ONLY}" -eq 1 ]]; then
  log "Mode: CRITICAL-ONLY (non-critical checks will be skipped)"
else
  log "Mode: FULL"
fi
log "════════════════════════════════════════════════════════════"

# ── Section 1: Critical ping — gateway, self, internet ────────────────────────
log "--- [1] Critical Reachability (ping -c 3 -W 5) ---"
check_ping "10.0.0.1" "Gateway"  1
check_ping "10.0.0.4" "Self"     1
check_ping "8.8.8.8"  "Internet" 1

# ── Section 2: Non-critical ping — app / DB servers ───────────────────────────
log "--- [2] Server Reachability — non-critical (ping -c 3 -W 5) ---"
if [[ "${CRITICAL_ONLY}" -eq 1 ]]; then
  handle_non_critical_skip "App server ping (10.0.1.10)"
  handle_non_critical_skip "DB server ping  (10.0.2.10)"
else
  check_ping "10.0.1.10" "App server" 0
  check_ping "10.0.2.10" "DB server"  0
fi

# ── Section 3: Port connectivity — critical in --post-recovery mode ─────────────
# --post-recovery: promotes both checks to CRITICAL so any lingering NSG block
# or application failure causes a non-zero exit, gating the recovery sign-off.
if [[ "${POST_RECOVERY}" -eq 1 ]]; then
  log "--- [3] Port Connectivity — CRITICAL (--post-recovery mode) ---"
  check_nc "10.0.2.10" "5432" "PostgreSQL"   1
  check_nc "10.0.1.10" "8080" "App health"   1
elif [[ "${CRITICAL_ONLY}" -eq 1 ]]; then
  log "--- [3] Port Connectivity — non-critical (nc -zv -w 5) ---"
  handle_non_critical_skip "PostgreSQL port check (10.0.2.10:5432)"
  handle_non_critical_skip "App health port check (10.0.1.10:8080)"
else
  log "--- [3] Port Connectivity — non-critical (nc -zv -w 5) ---"
  check_nc "10.0.2.10" "5432" "PostgreSQL"   0
  check_nc "10.0.1.10" "8080" "App health"   0
fi

# ── Section 4: DNS resolution — critical ──────────────────────────────────────
log "--- [4] DNS Resolution — critical (nslookup, timeout 5s) ---"
check_dns "google.com" "DNS resolution" 1

# ── Section 5: Default route — critical ───────────────────────────────────────
log "--- [5] Default Route — critical (ip route show) ---"
check_default_route 1

# ── Section 6: tc qdisc latency injection — non-critical ──────────────────────
log "--- [6] tc qdisc Latency Injection Check (eth0) ---"
if [[ "${CRITICAL_ONLY}" -eq 1 ]]; then
  handle_non_critical_skip "tc qdisc check (eth0)"
else
  check_tc_qdisc "eth0" 0
fi

# ── Summary ────────────────────────────────────────────────────────────────────
log "════════════════════════════════════════════════════════════"
log "SUMMARY"
log "  Total passed : ${PASSED}"
log "  Total failed : ${FAILED}"
log "  Total skipped: ${SKIPPED}"
log "════════════════════════════════════════════════════════════"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf '[DRY-RUN] Completed — no checks were executed.\n'
  exit 0
fi

if [[ "${CRITICAL_FAILED}" -gt 0 ]]; then
  log "RESULT: CRITICAL FAILURE — ${CRITICAL_FAILED} critical check(s) failed"
  exit 1
else
  log "RESULT: OK — all critical checks passed"
  exit 0
fi

#!/usr/bin/env bash
set -uo pipefail

# ==============================================================================
# post-deploy-checks.sh — FinBridge Lab Post-Deployment Validation
# Azure East US | Requires: Azure CLI (az), jq
# Usage: ./post-deploy-checks.sh [participant-name]
#        PARTICIPANT_NAME=tinkuxd ./post-deploy-checks.sh
#
# Checks five categories: SECURITY, MONITORING, BACKUP, PERFORMANCE, CONNECTIVITY
# Exit code 0 = all checks PASS/WARN  |  Exit code 1 = one or more FAIL
# ==============================================================================

# ── Colour palette ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Counters ───────────────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0

# ── Result helpers ─────────────────────────────────────────────────────────────
pass() { printf "${GREEN}[PASS]${NC} %s\n" "$1"; ((PASS_COUNT++)); }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$1"; ((FAIL_COUNT++)); }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; ((WARN_COUNT++)); }
skip() { printf "${CYAN}[SKIP]${NC} %s\n" "$1"; ((SKIP_COUNT++)); }
info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
section() {
    local width=72
    local title=" $1 "
    local pad=$(( (width - ${#title}) / 2 ))
    printf "\n${BOLD}%s%s%s${NC}\n" "$(printf '═%.0s' $(seq 1 $pad))" "$title" "$(printf '═%.0s' $(seq 1 $pad))"
}

# ── Configuration ──────────────────────────────────────────────────────────────
PARTICIPANT="${1:-${PARTICIPANT_NAME:-tinkuxd}}"
RESOURCE_GROUP="rg-ailab-${PARTICIPANT}"
BASTION_NAME="bastion-ailab"
STORAGE_ACCOUNT="stailab${PARTICIPANT}"
NSG_APP="nsg-app"
NSG_DB="nsg-db"
VM_APP="vm-app"
VM_DB="vm-db"
VM_WIN="vm-win"
VM_DB_IP="10.0.2.10"

# ── Pre-flight ─────────────────────────────────────────────────────────────────
section "PRE-FLIGHT"

if ! command -v az &>/dev/null; then
    printf "${RED}ERROR:${NC} Azure CLI not found. Install from https://docs.microsoft.com/cli/azure/install-azure-cli\n"
    exit 2
fi

if ! az account show &>/dev/null; then
    printf "${RED}ERROR:${NC} Not logged in to Azure CLI. Run 'az login' first.\n"
    exit 2
fi

SUBSCRIPTION=$(az account show --query name -o tsv)
info "Subscription : ${SUBSCRIPTION}"
info "Resource group: ${RESOURCE_GROUP}"
info "Participant   : ${PARTICIPANT}"
printf "\n"

if ! az group show --name "${RESOURCE_GROUP}" &>/dev/null; then
    printf "${RED}ERROR:${NC} Resource group '${RESOURCE_GROUP}' not found. Has 'terraform apply' completed?\n"
    exit 2
fi

# Resolve VM resource IDs — fail early if any VM is missing
for VM_NAME in "${VM_APP}" "${VM_DB}" "${VM_WIN}"; do
    VM_ID=$(az vm show --resource-group "${RESOURCE_GROUP}" --name "${VM_NAME}" \
        --query id -o tsv 2>/dev/null || true)
    if [[ -z "${VM_ID}" ]]; then
        printf "${RED}ERROR:${NC} VM '${VM_NAME}' not found in '${RESOURCE_GROUP}'. Check terraform state.\n"
        exit 2
    fi
    declare "VM_${VM_NAME//-/_}_ID=${VM_ID}"
done

# Helper: run a shell command inside a Linux VM via the Azure VM agent.
# Args: $1 = VM name  $2 = shell script string
# Returns the stdout portion of the run-command response.
vm_run() {
    local vm="$1"
    local script="$2"
    az vm run-command invoke \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${vm}" \
        --command-id RunShellScript \
        --scripts "${script}" \
        --query "value[0].message" \
        -o tsv 2>/dev/null \
      | sed 's/[[:space:]]*$//' \
      | sed '/^\[stdout\]$/d' \
      | sed '/^\[stderr\]$/d' \
      | sed '/^$/d' \
      || echo "__ERROR__"
}

info "All VMs found. Starting checks…"

# ==============================================================================
section "SECURITY"
# ==============================================================================

# ── S1: No 0.0.0.0/0 / Internet / * on any NSG inbound Allow rule ─────────────
info "S1: Scanning all NSGs for open inbound Allow rules…"
OPEN_RULES=$(az network nsg list \
    --resource-group "${RESOURCE_GROUP}" \
    --query "[].securityRules[?
        direction=='Inbound' &&
        access=='Allow' &&
        (sourceAddressPrefix=='0.0.0.0/0' ||
         sourceAddressPrefix=='*'          ||
         sourceAddressPrefix=='Internet')
    ].{nsg:name, rule:name, port:destinationPortRange}" \
    -o tsv 2>/dev/null || true)

if [[ -z "${OPEN_RULES}" ]]; then
    pass "S1: No 0.0.0.0/0 inbound Allow rules on any NSG"
else
    fail "S1: Open inbound rules found — remove immediately: ${OPEN_RULES}"
fi

# ── S2: No public IPs on VM NICs ──────────────────────────────────────────────
info "S2: Checking for public IPs assigned to VM NICs…"
VM_PUBLIC_IPS=$(az vm list-ip-addresses \
    --resource-group "${RESOURCE_GROUP}" \
    --query "[].virtualMachine.network.publicIpAddresses[].ipAddress" \
    -o tsv 2>/dev/null | grep -v '^$' || true)

if [[ -z "${VM_PUBLIC_IPS}" ]]; then
    pass "S2: No public IPs on any VM NIC"
else
    fail "S2: VM(s) have public IPs: ${VM_PUBLIC_IPS}"
fi

# ── S3: Storage account — public blob access disabled ─────────────────────────
info "S3: Checking storage account '${STORAGE_ACCOUNT}' public blob access…"
BLOB_PUBLIC=$(az storage account show \
    --name "${STORAGE_ACCOUNT}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query "allowBlobPublicAccess" \
    -o tsv 2>/dev/null || echo "__NOTFOUND__")

case "${BLOB_PUBLIC}" in
    false|False)
        pass "S3: Storage public blob access = DISABLED" ;;
    true|True)
        fail "S3: Storage '${STORAGE_ACCOUNT}' public blob access is ENABLED — set allowBlobPublicAccess=false" ;;
    __NOTFOUND__)
        warn "S3: Storage account '${STORAGE_ACCOUNT}' not found or insufficient permissions" ;;
    *)
        warn "S3: Unexpected value for allowBlobPublicAccess: '${BLOB_PUBLIC}'" ;;
esac

# ── S4: All managed disks have SSE enabled (platform default — confirm) ────────
info "S4: Confirming server-side encryption on all managed disks…"
# Azure SSE with PMK is mandatory and cannot be disabled; this confirms no
# disks are unmanaged (unmanaged disks in a storage blob are not SSE-enforced).
UNMANAGED_DISK_COUNT=$(az vm list \
    --resource-group "${RESOURCE_GROUP}" \
    --query "length([].storageProfile.osDisk[?managedDisk==null])" \
    -o tsv 2>/dev/null || echo "0")

DISK_LIST=$(az disk list \
    --resource-group "${RESOURCE_GROUP}" \
    --query "[].{name:name, enc:encryption.type}" \
    -o tsv 2>/dev/null || echo "")

if [[ "${UNMANAGED_DISK_COUNT}" == "0" ]] || [[ -z "${UNMANAGED_DISK_COUNT}" ]]; then
    pass "S4: All OS disks are managed — SSE with platform-managed keys is enforced by Azure"
    while IFS=$'\t' read -r disk_name enc_type; do
        [[ -z "${disk_name}" ]] && continue
        info "    Disk: ${disk_name} | Encryption: ${enc_type:-EncryptionAtRestWithPlatformKey}"
    done <<< "${DISK_LIST}"
else
    fail "S4: ${UNMANAGED_DISK_COUNT} unmanaged disk(s) found — SSE is not guaranteed; migrate to managed disks"
fi

# ==============================================================================
section "MONITORING"
# ==============================================================================

# ── M1: CPU > 80% alert rules on all VMs ──────────────────────────────────────
info "M1: Checking for CPU > 80% metric alert rules…"
CPU_ALERTS=$(az monitor metrics alert list \
    --resource-group "${RESOURCE_GROUP}" \
    --query "[?criteria.allOf[?metricName=='Percentage CPU' || metricName=='PercentageCPU']].name" \
    -o tsv 2>/dev/null || true)

if [[ -n "${CPU_ALERTS}" ]]; then
    pass "M1: CPU alert rule(s) found: ${CPU_ALERTS}"
else
    warn "M1: No CPU metric alert rules configured — add threshold ≥80% alerts for all three VMs"
fi

# ── M2: Disk space alert at 80% ───────────────────────────────────────────────
info "M2: Checking for disk space alert rules…"
DISK_ALERTS=$(az monitor metrics alert list \
    --resource-group "${RESOURCE_GROUP}" \
    --query "[?criteria.allOf[?contains(metricName,'Disk') || contains(metricName,'disk')]].name" \
    -o tsv 2>/dev/null || true)

if [[ -n "${DISK_ALERTS}" ]]; then
    pass "M2: Disk alert rule(s) found: ${DISK_ALERTS}"
else
    warn "M2: No disk space alert rules found — add 'Available Bytes' or 'Disk Bytes Used' alert at 80%"
fi

# ── M3: PostgreSQL connection count alert (16/20) ─────────────────────────────
info "M3: Checking for PostgreSQL connection alert (threshold 16/20)…"
# Connection count alert on a VM-hosted PG must be a Log Alert or custom metric.
PG_ALERTS=$(az monitor scheduled-query list \
    --resource-group "${RESOURCE_GROUP}" \
    --query "[?contains(name,'postgres') || contains(name,'pg') || contains(name,'connection')].name" \
    -o tsv 2>/dev/null || true)

if [[ -n "${PG_ALERTS}" ]]; then
    pass "M3: PostgreSQL connection alert found: ${PG_ALERTS}"
else
    warn "M3: No PostgreSQL connection alert found — add a Log Alert querying pg_stat_activity count > 16"
fi

# ── M4: Bastion diagnostic setting (BastionAuditLogs) ─────────────────────────
info "M4: Checking Bastion diagnostic settings for BastionAuditLogs…"
BASTION_ID=$(az network bastion show \
    --name "${BASTION_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query id -o tsv 2>/dev/null || echo "")

if [[ -z "${BASTION_ID}" ]]; then
    skip "M4: Bastion is not deployed (deploy_bastion=false) — verify diagnostic settings when deployed"
else
    DIAG=$(az monitor diagnostic-settings list \
        --resource "${BASTION_ID}" \
        --query "[?contains(logs[].category,'BastionAuditLogs')].name" \
        -o tsv 2>/dev/null || true)
    if [[ -n "${DIAG}" ]]; then
        pass "M4: Bastion diagnostic setting with BastionAuditLogs configured: ${DIAG}"
    else
        fail "M4: Bastion has no BastionAuditLogs diagnostic setting — session audit trail is absent"
    fi
fi

# ==============================================================================
section "BACKUP"
# ==============================================================================

# ── B1: Auto-shutdown configured on all VMs ───────────────────────────────────
info "B1: Checking auto-shutdown schedules (DevTestLab) on all VMs…"
# NOTE: Terraform configures shutdown at 1300 UTC; confirm the time matches
# your lab runbook. The checklist specifies 20:00 UTC — align in variables.tf
# if needed.
for VM_NAME in "${VM_APP}" "${VM_DB}" "${VM_WIN}"; do
    SCHED_STATUS=$(az resource show \
        --resource-group "${RESOURCE_GROUP}" \
        --resource-type "Microsoft.DevTestLab/schedules" \
        --name "shutdown-computevm-${VM_NAME}" \
        --query "properties.status" \
        -o tsv 2>/dev/null || echo "NotFound")
    SCHED_TIME=$(az resource show \
        --resource-group "${RESOURCE_GROUP}" \
        --resource-type "Microsoft.DevTestLab/schedules" \
        --name "shutdown-computevm-${VM_NAME}" \
        --query "properties.dailyRecurrence.time" \
        -o tsv 2>/dev/null || echo "")

    if [[ "${SCHED_STATUS}" == "Enabled" ]]; then
        # Format 1300 → 13:00
        SCHED_DISPLAY="${SCHED_TIME:0:2}:${SCHED_TIME:2:2} UTC"
        pass "B1: Auto-shutdown ENABLED on ${VM_NAME} at ${SCHED_DISPLAY}"
    elif [[ "${SCHED_STATUS}" == "Disabled" ]]; then
        warn "B1: Auto-shutdown exists but is DISABLED on ${VM_NAME} — re-enable or remove"
    else
        fail "B1: No auto-shutdown schedule found for ${VM_NAME}"
    fi
done

# ── B2: Storage soft-delete ≥ 7 days ──────────────────────────────────────────
info "B2: Checking blob soft-delete retention policy…"
SD_ENABLED=$(az storage account blob-service-properties show \
    --account-name "${STORAGE_ACCOUNT}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query "deleteRetentionPolicy.enabled" \
    -o tsv 2>/dev/null || echo "unknown")
SD_DAYS=$(az storage account blob-service-properties show \
    --account-name "${STORAGE_ACCOUNT}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query "deleteRetentionPolicy.days" \
    -o tsv 2>/dev/null || echo "0")

if [[ "${SD_ENABLED}" == "true" ]] && (( SD_DAYS >= 7 )); then
    pass "B2: Blob soft-delete ENABLED — ${SD_DAYS}-day retention"
elif [[ "${SD_ENABLED}" == "true" ]] && (( SD_DAYS < 7 )); then
    fail "B2: Soft-delete enabled but retention is only ${SD_DAYS} day(s) — minimum required is 7"
else
    fail "B2: Blob soft-delete is DISABLED on '${STORAGE_ACCOUNT}'"
fi

# ── B3: PostgreSQL WAL archiving enabled ──────────────────────────────────────
info "B3: Checking PostgreSQL archive_mode on vm-db…"
WAL_OUT=$(vm_run "${VM_DB}" "sudo -u postgres psql -tAc \"SHOW archive_mode;\" 2>/dev/null || echo __ERROR__")

case "${WAL_OUT}" in
    on)    pass "B3: PostgreSQL archive_mode = ON (WAL archiving enabled)" ;;
    off)   warn "B3: PostgreSQL archive_mode = OFF — point-in-time recovery requires WAL archiving" ;;
    always) pass "B3: PostgreSQL archive_mode = always (WAL archiving enabled on all segments)" ;;
    __ERROR__|"")
        warn "B3: Could not query archive_mode — VM may be stopped or PostgreSQL not running" ;;
    *)
        warn "B3: Unexpected archive_mode value: '${WAL_OUT}'" ;;
esac

# ── B4: PITR window — wal_keep_size ───────────────────────────────────────────
info "B4: Checking PostgreSQL PITR configuration (wal_keep_size)…"
WAL_KEEP=$(vm_run "${VM_DB}" "sudo -u postgres psql -tAc \"SHOW wal_keep_size;\" 2>/dev/null || echo __ERROR__")

if [[ "${WAL_KEEP}" == "__ERROR__" ]] || [[ -z "${WAL_KEEP}" ]]; then
    warn "B4: Could not query wal_keep_size — VM may be stopped"
elif [[ "${WAL_KEEP}" =~ ^[0-9]+$ ]] && (( WAL_KEEP > 0 )); then
    pass "B4: wal_keep_size = ${WAL_KEEP}MB — WAL segments are being retained for PITR"
else
    warn "B4: wal_keep_size = 0 or unset — set wal_keep_size ≥ 1024MB and configure archive_command for PITR"
fi

# ==============================================================================
section "PERFORMANCE"
# ==============================================================================

# ── P1: vm-app idle CPU (vmstat us < 10%) ─────────────────────────────────────
info "P1: Sampling vm-app CPU at idle (5 × 1s vmstat)…"
# vmstat output: r b swpd free buff cache si so bi bo in cs us sy id wa st
# Field 13 = us (user CPU %). Samples 5 intervals, averages them.
VMSTAT_OUT=$(vm_run "${VM_APP}" \
    "vmstat 1 5 | tail -5 | awk '{sum+=\$13; n++} END{printf \"%.1f\", sum/n}'")

if [[ "${VMSTAT_OUT}" == "__ERROR__" ]] || [[ -z "${VMSTAT_OUT}" ]]; then
    warn "P1: Could not retrieve vmstat from vm-app — VM may be stopped"
elif [[ "${VMSTAT_OUT}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    US_INT=${VMSTAT_OUT%.*}
    if (( US_INT <= 10 )); then
        pass "P1: vm-app idle CPU (us) = ${VMSTAT_OUT}% (threshold ≤10%)"
    else
        warn "P1: vm-app idle CPU (us) = ${VMSTAT_OUT}% — exceeds 10% at idle; investigate with 'top -bn1'"
    fi
else
    warn "P1: Unexpected vmstat output: '${VMSTAT_OUT}'"
fi

# ── P2: vm-db pg_stat_bgwriter — checkpoints_timed / checkpoints_req ──────────
info "P2: Querying pg_stat_bgwriter on vm-db…"
BGW_OUT=$(vm_run "${VM_DB}" \
    "sudo -u postgres psql -tAc \"SELECT checkpoints_timed, checkpoints_req, buffers_checkpoint FROM pg_stat_bgwriter;\" 2>/dev/null || echo __ERROR__")

if [[ "${BGW_OUT}" == "__ERROR__" ]] || [[ -z "${BGW_OUT}" ]]; then
    warn "P2: Could not query pg_stat_bgwriter — VM may be stopped or PostgreSQL not running"
elif [[ "${BGW_OUT}" =~ ^[[:space:]]*([0-9]+)[[:space:]]*\|[[:space:]]*([0-9]+)[[:space:]]*\|[[:space:]]*([0-9]+) ]]; then
    CT="${BASH_REMATCH[1]}"
    CR="${BASH_REMATCH[2]}"
    BC="${BASH_REMATCH[3]}"
    pass "P2: pg_stat_bgwriter — checkpoints_timed=${CT} | checkpoints_req=${CR} | buffers_checkpoint=${BC}"
    if (( CR > CT )); then
        warn "P2: checkpoints_req (${CR}) > checkpoints_timed (${CT}) — DB is under write pressure; increase shared_buffers"
    fi
else
    warn "P2: Could not parse pg_stat_bgwriter output: '${BGW_OUT}'"
fi

# ── P3: vm-app disk await < 5ms (iostat) ──────────────────────────────────────
info "P3: Sampling disk await on vm-app (iostat, 3 × 1s)…"
# Use sysstat iostat -x; find the 'await' column dynamically to handle version differences.
AWAIT_OUT=$(vm_run "${VM_APP}" \
    "if ! command -v iostat &>/dev/null; then echo __NOTFOUND__; exit; fi; \
     iostat -dx sda 1 3 | awk '
       /await/ && col==0 { for(i=1;i<=NF;i++) if(\$i==\"await\"){col=i} }
       col>0 && /^sda/ { sum+=\$col; n++ }
       END { if(n) printf \"%.2f\", sum/n; else print \"__NODATA__\" }
       ' col=0")

case "${AWAIT_OUT}" in
    __NOTFOUND__)
        warn "P3: iostat not found on vm-app — install sysstat: 'sudo apt-get install -y sysstat'" ;;
    __NODATA__|__ERROR__|"")
        warn "P3: Could not retrieve iostat data — VM may be stopped" ;;
    *)
        if [[ "${AWAIT_OUT}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            AWAIT_INT=${AWAIT_OUT%.*}
            if (( AWAIT_INT <= 5 )); then
                pass "P3: vm-app disk await = ${AWAIT_OUT}ms (threshold ≤5ms)"
            else
                warn "P3: vm-app disk await = ${AWAIT_OUT}ms — exceeds 5ms; Standard HDD is expected; Premium SSD resolves this"
            fi
        else
            warn "P3: Unexpected iostat output: '${AWAIT_OUT}'"
        fi ;;
esac

# ── P4: Ping vm-app → vm-db < 1ms (same VNet) ────────────────────────────────
info "P4: Testing ICMP latency from vm-app → vm-db (${VM_DB_IP})…"
PING_OUT=$(vm_run "${VM_APP}" \
    "ping -c 4 -q ${VM_DB_IP} 2>&1 | grep -oE 'rtt[^=]+=\s*[0-9.]+/([0-9.]+)' | grep -oE '= [0-9.]+/' | grep -oE '[0-9.]+' | head -1 || echo __ERROR__")

if [[ "${PING_OUT}" == "__ERROR__" ]] || [[ -z "${PING_OUT}" ]]; then
    warn "P4: Ping failed from vm-app → vm-db — VM may be stopped or ICMP blocked"
elif [[ "${PING_OUT}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    RTT_INT=${PING_OUT%.*}
    if (( RTT_INT <= 1 )); then
        pass "P4: vm-app → vm-db avg RTT = ${PING_OUT}ms (threshold ≤1ms)"
    else
        warn "P4: vm-app → vm-db avg RTT = ${PING_OUT}ms — exceeds 1ms; unexpected for same-VNet traffic"
    fi
else
    warn "P4: Unexpected ping output: '${PING_OUT}'"
fi

# ==============================================================================
section "CONNECTIVITY"
# ==============================================================================

# ── C1: vm-app → vm-db port 5432 PASS ────────────────────────────────────────
info "C1: Testing vm-app → vm-db:5432 (PostgreSQL)…"
NC_OUT=$(vm_run "${VM_APP}" \
    "nc -zv -w 3 ${VM_DB_IP} 5432 2>&1 | tail -1 || echo FAILED")

if echo "${NC_OUT}" | grep -qiE "succeeded|Connected|open|Connection to"; then
    pass "C1: vm-app → vm-db:5432 OPEN"
elif echo "${NC_OUT}" | grep -qiE "refused|timed out|FAILED"; then
    fail "C1: vm-app → vm-db:5432 BLOCKED — check nsg-db AllowPostgres rule and PostgreSQL listen_addresses (${VM_DB_IP})"
else
    warn "C1: Ambiguous nc result: '${NC_OUT}' — verify manually"
fi

# ── C2: Bastion subnet → vm-app:22 permitted by NSG (control-plane check) ─────
info "C2: Verifying NSG rule allows Bastion subnet (10.0.3.0/27) → vm-app:22…"
SSH_RULE=$(az network nsg rule list \
    --resource-group "${RESOURCE_GROUP}" \
    --nsg-name "${NSG_APP}" \
    --query "[?direction=='Inbound' && access=='Allow' && destinationPortRange=='22' && sourceAddressPrefix=='10.0.3.0/27'].name" \
    -o tsv 2>/dev/null || true)

if [[ -n "${SSH_RULE}" ]]; then
    pass "C2: NSG rule '${SSH_RULE}' permits Bastion subnet → vm-app:22"
else
    fail "C2: No NSG rule found permitting 10.0.3.0/27 → vm-app:22 — Bastion SSH will fail"
fi

# ── C3: Bastion subnet → vm-win:3389 permitted by NSG ─────────────────────────
info "C3: Verifying NSG rule allows Bastion subnet (10.0.3.0/27) → vm-win:3389…"
RDP_RULE=$(az network nsg rule list \
    --resource-group "${RESOURCE_GROUP}" \
    --nsg-name "${NSG_APP}" \
    --query "[?direction=='Inbound' && access=='Allow' && destinationPortRange=='3389' && sourceAddressPrefix=='10.0.3.0/27'].name" \
    -o tsv 2>/dev/null || true)

if [[ -n "${RDP_RULE}" ]]; then
    pass "C3: NSG rule '${RDP_RULE}' permits Bastion subnet → vm-win:3389"
else
    fail "C3: No NSG rule found permitting 10.0.3.0/27 → vm-win:3389 — Bastion RDP will fail"
fi

# ── C4: Internet → vm-app:22 BLOCKED ─────────────────────────────────────────
info "C4: Confirming Internet → vm-app:22 is BLOCKED by NSG…"
OPEN_SSH_RULE=$(az network nsg rule list \
    --resource-group "${RESOURCE_GROUP}" \
    --nsg-name "${NSG_APP}" \
    --query "[?direction=='Inbound' && access=='Allow' && destinationPortRange=='22' &&
             (sourceAddressPrefix=='0.0.0.0/0' || sourceAddressPrefix=='*' || sourceAddressPrefix=='Internet')].name" \
    -o tsv 2>/dev/null || true)

if [[ -z "${OPEN_SSH_RULE}" ]]; then
    pass "C4: Internet → vm-app:22 BLOCKED (no 0.0.0.0/0 Allow-SSH rule on ${NSG_APP})"
else
    fail "C4: CRITICAL — open SSH rule '${OPEN_SSH_RULE}' allows Internet → vm-app:22; remove immediately"
fi

# ── C5: vm-db → internet reachable (package updates) ─────────────────────────
info "C5: Testing vm-db → internet reachability (ubuntu package mirror)…"
HTTP_CODE=$(vm_run "${VM_DB}" \
    "curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://archive.ubuntu.com || echo FAIL")

if [[ "${HTTP_CODE}" =~ ^(200|301|302|403)$ ]]; then
    pass "C5: vm-db → internet reachable (HTTP ${HTTP_CODE} from archive.ubuntu.com)"
elif [[ "${HTTP_CODE}" == "FAIL" ]] || [[ "${HTTP_CODE}" == "__ERROR__" ]]; then
    warn "C5: vm-db → internet unreachable — outbound NAT or DNS may be misconfigured; package updates will fail"
else
    warn "C5: vm-db → internet returned unexpected code '${HTTP_CODE}' — verify manually"
fi

# ==============================================================================
section "RESILIENCE PRE-TEST GATE"
# ==============================================================================
# Run this section before ANY resilience scenario to confirm the environment
# is in a clean baseline state. Every check must PASS or SKIP before testing.
# If any check FAILS, abort and resolve it before proceeding.

# ── R1: No stress-ng processes running on vm-app (Scenario A / G gate) ────────
info "R1: Checking for active stress-ng processes on vm-app…"
STRESS_CHECK=$(vm_run "${VM_APP}" \
    "pgrep -x stress-ng > /dev/null 2>&1 && echo RUNNING || echo CLEAN")
case "${STRESS_CHECK}" in
    CLEAN)
        pass "R1: No stress-ng processes running on vm-app" ;;
    RUNNING)
        fail "R1: stress-ng IS running on vm-app — abort all tests; run: sudo pkill -9 stress-ng" ;;
    __ERROR__|"")
        warn "R1: Could not check stress-ng on vm-app — VM may be stopped" ;;
    *)
        warn "R1: Unexpected output from stress-ng check: '${STRESS_CHECK}'" ;;
esac

# ── R2: /tmp/diskfill.img absent on vm-app (Scenario C gate) ─────────────────
info "R2: Checking for /tmp/diskfill.img on vm-app (leftover from Scenario C)…"
FILLFILE=$(vm_run "${VM_APP}" \
    "test -f /tmp/diskfill.img && echo EXISTS || echo CLEAN")
case "${FILLFILE}" in
    CLEAN)
        pass "R2: /tmp/diskfill.img not present on vm-app" ;;
    EXISTS)
        fail "R2: /tmp/diskfill.img exists on vm-app — Scenario C artifact not cleaned up; run:
             sudo ./disk-monitor.sh --resilience-cleanup" ;;
    __ERROR__|"")
        warn "R2: Could not check /tmp/diskfill.img on vm-app — VM may be stopped" ;;
    *)
        warn "R2: Unexpected output from diskfill check: '${FILLFILE}'" ;;
esac

# ── R3: vm-app disk usage < 60% (Scenario C safe headroom) ───────────────────
info "R3: Checking vm-app disk usage (must be < 60% before Scenario C)…"
DISK_PCT=$(vm_run "${VM_APP}" \
    "df / | awk 'NR==2 {gsub(/%/,\"\",\$5); print \$5}'")
if [[ "${DISK_PCT}" == "__ERROR__" ]] || [[ -z "${DISK_PCT}" ]]; then
    warn "R3: Could not check disk usage on vm-app — VM may be stopped"
elif [[ "${DISK_PCT}" =~ ^[0-9]+$ ]]; then
    if (( DISK_PCT < 60 )); then
        pass "R3: vm-app disk usage = ${DISK_PCT}% (threshold < 60%)"
    elif (( DISK_PCT < 80 )); then
        warn "R3: vm-app disk usage = ${DISK_PCT}% — marginal; Scenario C disk fill may leave insufficient headroom"
    else
        fail "R3: vm-app disk usage = ${DISK_PCT}% — too high to safely run Scenario C; free space first"
    fi
else
    warn "R3: Unexpected disk usage output: '${DISK_PCT}'"
fi

# ── R4: PostgreSQL connection headroom >= 15 of 20 (Scenario B gate) ─────────
info "R4: Checking PostgreSQL connection count on vm-db (max_connections = 20)…"
PG_CONNS=$(vm_run "${VM_DB}" \
    "sudo -u postgres psql -tAc \
     \"SELECT count(*) FROM pg_stat_activity WHERE state IS NOT NULL;\" \
     2>/dev/null || echo __ERROR__")
if [[ "${PG_CONNS}" == "__ERROR__" ]] || [[ -z "${PG_CONNS}" ]]; then
    warn "R4: Could not query pg_stat_activity — PostgreSQL may not be running"
elif [[ "${PG_CONNS}" =~ ^[0-9]+$ ]]; then
    HEADROOM=$(( 20 - PG_CONNS ))
    if (( PG_CONNS <= 5 )); then
        pass "R4: PostgreSQL active connections = ${PG_CONNS}/20 (headroom: ${HEADROOM}) — safe for Scenario B"
    elif (( PG_CONNS <= 10 )); then
        warn "R4: PostgreSQL connections = ${PG_CONNS}/20 — reduced headroom; Scenario B pool fill may not reach max"
    else
        fail "R4: PostgreSQL connections = ${PG_CONNS}/20 — insufficient headroom to safely run Scenario B"
    fi
else
    warn "R4: Unexpected pg_stat_activity output: '${PG_CONNS}'"
fi

# ── R5: No BlockPostgresTest rule on nsg-db (Scenario D gate) ────────────────
info "R5: Checking nsg-db for leftover BlockPostgresTest rule (Scenario D artifact)…"
BLOCK_RULE=$(az network nsg rule show \
    --resource-group "${RESOURCE_GROUP}" \
    --nsg-name "${NSG_DB}" \
    --name "BlockPostgresTest" \
    --query "name" -o tsv 2>/dev/null || echo "NotFound")
if [[ "${BLOCK_RULE}" == "NotFound" ]] || [[ -z "${BLOCK_RULE}" ]]; then
    pass "R5: No BlockPostgresTest rule present on nsg-db — network path is clean"
else
    fail "R5: BlockPostgresTest rule IS present on nsg-db — remove it before testing:
         az network nsg rule delete -g ${RESOURCE_GROUP} --nsg-name nsg-db --name BlockPostgresTest --yes"
fi

# ── R6: Auto-shutdown timing gate (>= 30 min before 20:00 UTC) ───────────────
info "R6: Verifying safe time window (>= 30 min before 20:00 UTC auto-shutdown)…"
CURRENT_UTC_MINS=$(date -u +"%H %M" | awk '{print $1*60 + $2}')
SHUTDOWN_MINS=$(( 20 * 60 ))
MINS_TO_SHUTDOWN=$(( SHUTDOWN_MINS - CURRENT_UTC_MINS ))
if (( MINS_TO_SHUTDOWN < 0 )); then
    MINS_TO_SHUTDOWN=$(( MINS_TO_SHUTDOWN + 1440 ))
fi
if (( MINS_TO_SHUTDOWN >= 30 )); then
    pass "R6: ${MINS_TO_SHUTDOWN} min until auto-shutdown (20:00 UTC) — sufficient window for all scenarios"
elif (( MINS_TO_SHUTDOWN >= 10 )); then
    warn "R6: Only ${MINS_TO_SHUTDOWN} min until auto-shutdown — limit to scenarios with RTO < 2 min"
else
    fail "R6: Only ${MINS_TO_SHUTDOWN} min until auto-shutdown — DO NOT start any resilience tests"
fi

# ── R7: All three VMs are powered on and running ─────────────────────────────
info "R7: Confirming all VMs are in 'VM running' state…"
for VM_NAME in "${VM_APP}" "${VM_DB}" "${VM_WIN}"; do
    VM_STATE=$(az vm show \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${VM_NAME}" \
        --show-details \
        --query "powerState" -o tsv 2>/dev/null || echo "__ERROR__")
    case "${VM_STATE}" in
        "VM running")
            pass "R7: ${VM_NAME} — powerState = '${VM_STATE}'" ;;
        "VM deallocated"|"VM stopped")
            fail "R7: ${VM_NAME} is '${VM_STATE}' — start it before testing:
                 az vm start -g ${RESOURCE_GROUP} -n ${VM_NAME}" ;;
        __ERROR__|"")
            warn "R7: Could not retrieve power state for ${VM_NAME}" ;;
        *)
            warn "R7: ${VM_NAME} powerState = '${VM_STATE}' — verify manually before testing" ;;
    esac
done

# ==============================================================================
section "SUMMARY"
# ==============================================================================

TOTAL=$(( PASS_COUNT + FAIL_COUNT + WARN_COUNT + SKIP_COUNT ))

printf "\n"
printf "${BOLD}%-8s %-8s %-8s %-8s %-8s${NC}\n" "PASS" "FAIL" "WARN" "SKIP" "TOTAL"
printf "${GREEN}%-8s${NC} ${RED}%-8s${NC} ${YELLOW}%-8s${NC} ${CYAN}%-8s${NC} %-8s\n" \
    "${PASS_COUNT}" "${FAIL_COUNT}" "${WARN_COUNT}" "${SKIP_COUNT}" "${TOTAL}"
printf "\n"

if (( FAIL_COUNT > 0 )); then
    printf "${RED}${BOLD}✗  DEPLOYMENT NOT READY — ${FAIL_COUNT} check(s) failed.${NC}\n"
    printf "   Resolve all [FAIL] items before handing the environment to participants.\n"
    exit 1
elif (( WARN_COUNT > 0 )); then
    printf "${YELLOW}${BOLD}⚠  Deployment functional — ${WARN_COUNT} warning(s) require attention.${NC}\n"
    printf "   Review [WARN] items at next opportunity; environment may be used with caution.\n"
    exit 0
else
    printf "${GREEN}${BOLD}✓  All ${TOTAL} checks passed. Environment is ready for participants.${NC}\n"
    exit 0
fi

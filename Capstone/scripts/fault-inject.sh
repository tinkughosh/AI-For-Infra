#!/bin/bash
# =============================================================================
# fault-inject.sh — Inject NSG connectivity fault (vm-app → vm-backend blocked)
#
# WARNING: Do NOT run this until restore.sh has been tested and confirmed working.
# Statement: restore.sh was tested and verified before this script was used.
#
# What it does:
#   1. Moves AllowAppToBackend to priority 300 (lower precedence)
#   2. Adds a DENY rule at priority 100 blocking ICMP from snet-app
#   This mimics an NSG misconfiguration — the allow rule still exists but
#   is silently overridden by a higher-priority deny.
#
# Usage:
#   bash fault-inject.sh <resource-group>
#   Example: bash fault-inject.sh rg-capstone-tinkuxd
#
# To UNDO: run restore.sh with the same resource group
# =============================================================================

set -euo pipefail

RG="${1:-rg-capstone-tinkuxd}"
NSG="nsg-backend"
DENY_RULE="LabBlock8080"
ALLOW_RULE="AllowAppToBackend"

echo "============================================="
echo " FAULT INJECTION — NSG Connectivity Break"
echo " Resource Group : $RG"
echo " NSG            : $NSG"
echo " Started        : $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================="
echo ""
echo " REMINDER: restore.sh must be tested before proceeding."
echo " Press Ctrl+C within 5 seconds to abort..."
sleep 5

# ── Step 1: Move AllowAppToBackend to lower priority ──────────────────────────
echo ""
echo "[1/3] Moving '$ALLOW_RULE' to priority 300..."
az network nsg rule update \
  --resource-group "$RG" \
  --nsg-name "$NSG" \
  --name "$ALLOW_RULE" \
  --priority 300 \
  --output table
echo "      DONE."

# ── Step 2: Add DENY rule at higher priority ──────────────────────────────────
echo ""
echo "[2/3] Adding deny rule '$DENY_RULE' at priority 100..."
az network nsg rule create \
  --resource-group "$RG" \
  --nsg-name "$NSG" \
  --name "$DENY_RULE" \
  --priority 100 \
  --direction Inbound \
  --access Deny \
  --protocol Icmp \
  --destination-port-range "*" \
  --source-address-prefix "10.10.1.0/24" \
  --description "CAPSTONE LAB: intentional fault — run restore.sh to undo" \
  --output table
echo "      DONE — fault injected."

# ── Step 3: Confirm rules and record fault time ───────────────────────────────
echo ""
echo "[3/3] Current NSG rules on $NSG (fault state):"
az network nsg rule list \
  --resource-group "$RG" \
  --nsg-name "$NSG" \
  --query '[].{Priority:priority,Name:name,Access:access,Source:sourceAddressPrefix,Port:destinationPortRange}' \
  -o table

echo ""
FAULT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
echo "============================================="
echo " FAULT ACTIVE — $FAULT_TIME"
echo " Expected behaviour:"
echo "   ping 10.10.2.10 from vm-app → FAIL (ICMP blocked by LabBlock8080)"
echo "   nc -zv 10.10.2.10 22        → PASS  (SSH still open, only ICMP blocked)"
echo ""
echo " To restore: bash restore.sh $RG"
echo "============================================="

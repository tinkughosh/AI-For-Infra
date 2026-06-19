#!/bin/bash
# =============================================================================
# restore.sh — Restore NSG connectivity between vm-app and vm-backend
#
# GRADED GATE: This script was written and tested BEFORE fault-inject.sh was run.
#
# What it does:
#   Removes the LabBlock8080 deny rule (if present) and ensures the
#   AllowAppToBackend rule source is set back to the correct subnet (10.10.1.0/24).
#
# Usage:
#   bash restore.sh <resource-group>
#   Example: bash restore.sh rg-capstone-tinkuxd
#
# Prerequisites: az CLI logged in (or ARM_* env vars set)
# =============================================================================

set -euo pipefail

RG="${1:-rg-capstone-tinkuxd}"
NSG="nsg-backend"
DENY_RULE="LabBlock8080"
ALLOW_RULE="AllowAppToBackend"
CORRECT_SOURCE="10.10.1.0/24"

echo "============================================="
echo " RESTORE SCRIPT — NSG Connectivity Fix"
echo " Resource Group : $RG"
echo " NSG            : $NSG"
echo " Started        : $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================="

# ── Step 1: Remove the deny rule if it exists ─────────────────────────────────
echo ""
echo "[1/3] Checking for deny rule '$DENY_RULE'..."
RULE_EXISTS=$(az network nsg rule show \
  --resource-group "$RG" \
  --nsg-name "$NSG" \
  --name "$DENY_RULE" \
  --query "name" -o tsv 2>/dev/null || echo "")

if [ -n "$RULE_EXISTS" ]; then
  echo "      Found. Deleting '$DENY_RULE'..."
  az network nsg rule delete \
    --resource-group "$RG" \
    --nsg-name "$NSG" \
    --name "$DENY_RULE"
  echo "      DONE — deny rule removed."
else
  echo "      Not found — nothing to delete."
fi

# ── Step 2: Restore AllowAppToBackend source to correct subnet ────────────────
echo ""
echo "[2/3] Restoring '$ALLOW_RULE' source to $CORRECT_SOURCE..."
az network nsg rule update \
  --resource-group "$RG" \
  --nsg-name "$NSG" \
  --name "$ALLOW_RULE" \
  --source-address-prefix "$CORRECT_SOURCE" \
  --priority 200 \
  --output table
echo "      DONE — allow rule restored."

# ── Step 3: Validate current NSG rules ────────────────────────────────────────
echo ""
echo "[3/3] Current NSG rules on $NSG:"
az network nsg rule list \
  --resource-group "$RG" \
  --nsg-name "$NSG" \
  --query '[].{Priority:priority,Name:name,Access:access,Source:sourceAddressPrefix,Port:destinationPortRange}' \
  -o table

echo ""
echo "============================================="
echo " RESTORE COMPLETE — $(date '+%Y-%m-%d %H:%M:%S')"
echo " Next: SSH to vm-app and run:"
echo "   ping -c 4 10.10.2.10"
echo " Expected: 4 packets received (PASS)"
echo "============================================="

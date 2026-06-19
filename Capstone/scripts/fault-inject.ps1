# fault-inject.ps1 — Inject NSG fault (blocks ICMP from vm-app to vm-backend)
# IMPORTANT: Run restore.ps1 and confirm it works BEFORE running this script.
# To undo: .\restore.ps1

$RG         = "rg-capstone-tinkuxd"
$NSG        = "nsg-backend"
$DENY_RULE  = "LabBlock8080"
$ALLOW_RULE = "AllowAppToBackend"

Write-Host "=============================================" -ForegroundColor Yellow
Write-Host " FAULT INJECTION - NSG Connectivity Break"
Write-Host " Resource Group : $RG"
Write-Host " Started        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "============================================="
Write-Host ""
Write-Host " REMINDER: restore.ps1 must be tested before proceeding." -ForegroundColor Red
Write-Host " Press Ctrl+C within 5 seconds to abort..."
Start-Sleep -Seconds 5

# Step 1: Move AllowAppToBackend to lower priority
Write-Host ""
Write-Host "[1/3] Moving '$ALLOW_RULE' to priority 300..."
az network nsg rule update --resource-group $RG --nsg-name $NSG --name $ALLOW_RULE --priority 300 --output table
Write-Host "      DONE." -ForegroundColor Green

# Step 2: Add DENY rule at priority 150 (between AllowSSH=100 and AllowAppToBackend=300)
Write-Host ""
Write-Host "[2/3] Adding deny rule '$DENY_RULE' at priority 150 (blocks ICMP)..."
az network nsg rule create --resource-group $RG --nsg-name $NSG --name $DENY_RULE --priority 150 --direction Inbound --access Deny --protocol Icmp --destination-port-range "*" --source-address-prefix "10.10.1.0/24" --description "CAPSTONE LAB: intentional fault - run restore.ps1 to undo" --output table
Write-Host "      DONE - fault injected." -ForegroundColor Yellow

# Step 3: Show current rules
Write-Host ""
Write-Host "[3/3] Current NSG rules on $NSG (fault state):"
$query = "[].{Priority:priority,Name:name,Access:access,Protocol:protocol}"
az network nsg rule list --resource-group $RG --nsg-name $NSG --query $query -o table

$faultTime = Get-Date -Format 'HH:mm:ss'
Write-Host ""
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host " FAULT ACTIVE - $faultTime"
Write-Host " On vm-app: ping 10.10.2.10 should now FAIL"
Write-Host " To restore: .\restore.ps1"
Write-Host "=============================================" -ForegroundColor Yellow

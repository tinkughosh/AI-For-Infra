# restore.ps1 — Restore NSG connectivity between vm-app and vm-backend
# Usage: .\restore.ps1

$RG          = "rg-capstone-tinkuxd"
$NSG         = "nsg-backend"
$DENY_RULE   = "LabBlock8080"
$ALLOW_RULE  = "AllowAppToBackend"
$CORRECT_SRC = "10.10.1.0/24"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " RESTORE SCRIPT - NSG Connectivity Fix"
Write-Host " Resource Group : $RG"
Write-Host " Started        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "============================================="

# Step 1: Remove deny rule if it exists
Write-Host ""
Write-Host "[1/3] Checking for deny rule '$DENY_RULE'..."
$exists = az network nsg rule show --resource-group $RG --nsg-name $NSG --name $DENY_RULE --query "name" -o tsv 2>$null
if ($LASTEXITCODE -eq 0 -and $exists) {
    Write-Host "      Found. Deleting..." -ForegroundColor Yellow
    az network nsg rule delete --resource-group $RG --nsg-name $NSG --name $DENY_RULE
    Write-Host "      DONE - deny rule removed." -ForegroundColor Green
} else {
    Write-Host "      Not found - nothing to delete." -ForegroundColor Green
}

# Step 2: Reset AllowAppToBackend to correct source and priority
Write-Host ""
Write-Host "[2/3] Restoring '$ALLOW_RULE' source to $CORRECT_SRC at priority 200..."
az network nsg rule update --resource-group $RG --nsg-name $NSG --name $ALLOW_RULE --source-address-prefix $CORRECT_SRC --priority 200 --output table
Write-Host "      DONE." -ForegroundColor Green

# Step 3: Show current rules
Write-Host ""
Write-Host "[3/3] Current NSG rules on $NSG :"
$query = "[].{Priority:priority,Name:name,Access:access,Protocol:protocol}"
az network nsg rule list --resource-group $RG --nsg-name $NSG --query $query -o table

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " RESTORE COMPLETE - $(Get-Date -Format 'HH:mm:ss')"
Write-Host " Verify on vm-app: ping -c 4 10.10.2.10"
Write-Host " Expected        : 4 packets received"
Write-Host "=============================================" -ForegroundColor Cyan

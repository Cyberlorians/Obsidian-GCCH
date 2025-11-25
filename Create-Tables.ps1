<#
.SYNOPSIS
    Creates custom Log Analytics tables for Obsidian Security connector (GCCH)

.DESCRIPTION
    Creates ObsidianActivity_CL and ObsidianThreat_CL tables in the Log Analytics workspace.
    Run this BEFORE Deploy-Obsidian.ps1

.NOTES
    Requires: Az.Accounts, Az.Resources, Az.OperationalInsights modules
    Fill out config.json before running
#>

param(
    [string]$ConfigPath = ".\config.json"
)

$ErrorActionPreference = "Stop"

# Load config
Write-Host "Loading config..." -ForegroundColor Cyan
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config file not found: $ConfigPath"
    exit 1
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
Write-Host "[OK] Config loaded" -ForegroundColor Green

# Connect to Azure Government (non-interactive using config values)
Write-Host "Connecting to Azure Government..." -ForegroundColor Cyan
Write-Host "  Tenant: $($config.tenantId)"
Write-Host "  Subscription: $($config.subscriptionId)"
Connect-AzAccount -Environment AzureUSGovernment -TenantId $config.tenantId -SubscriptionId $config.subscriptionId -ErrorAction Stop | Out-Null
Write-Host "[OK] Connected to Azure Government" -ForegroundColor Green

# Get workspace resource ID
if ($config.workspaceResourceId) {
    $workspaceResourceId = $config.workspaceResourceId
} else {
    $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $config.resourceGroup -Name $config.workspaceName -ErrorAction Stop
    $workspaceResourceId = $workspace.ResourceId
}
Write-Host "[OK] Workspace: $workspaceResourceId" -ForegroundColor Green

# Get access token for GCCH management API
# Get access token for GCCH management API (convert SecureString to plain text for newer Az.Accounts versions)
$tokenObj = Get-AzAccessToken -ResourceUrl "https://management.usgovcloudapi.net"
$token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenObj.Token))

# Function to create table via REST API
function New-CustomTable {
    param(
        [string]$TableDefinitionPath,
        [string]$WorkspaceResourceId,
        [string]$Token
    )
    
    $tableJson = Get-Content $TableDefinitionPath -Raw | ConvertFrom-Json
    $tableName = $tableJson.name
    
    Write-Host "`nCreating table: $tableName..." -ForegroundColor Cyan
    Write-Host "  Columns: $($tableJson.properties.schema.columns.Count)"
    
    # Build the REST API URL for GCCH
    $apiVersion = "2022-10-01"
    $tableUrl = "https://management.usgovcloudapi.net$WorkspaceResourceId/tables/${tableName}?api-version=$apiVersion"
    
    # Build request body
    $body = @{
        properties = @{
            schema = @{
                name = $tableName
                columns = $tableJson.properties.schema.columns
            }
        }
    } | ConvertTo-Json -Depth 20
    
    try {
        $response = Invoke-RestMethod -Uri $tableUrl -Method PUT -Body $body -ContentType "application/json" -Headers @{ Authorization = "Bearer $Token" } -ErrorAction Stop
        Write-Host "[OK] Table $tableName created successfully" -ForegroundColor Green
        return $true
    } catch {
        if ($_.Exception.Response.StatusCode -eq 409 -or $_.ErrorDetails.Message -match "already exists") {
            Write-Host "[OK] Table $tableName already exists" -ForegroundColor Yellow
            return $true
        }
        Write-Host "[ERROR] Failed to create table $tableName" -ForegroundColor Red
        Write-Host "  Status: $($_.Exception.Response.StatusCode)" -ForegroundColor Red
        Write-Host "  Error: $($_.ErrorDetails.Message)" -ForegroundColor Red
        return $false
    }
}

# Get script directory
$scriptDir = Split-Path $ConfigPath -Parent
if (-not $scriptDir) { $scriptDir = "." }

Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "   Creating Custom Tables" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

# Create Activity table
$activityPath = Join-Path $scriptDir "ObsidianDatasharing_tableActivity.json"
if (Test-Path $activityPath) {
    $result1 = New-CustomTable -TableDefinitionPath $activityPath -WorkspaceResourceId $workspaceResourceId -Token $token
} else {
    Write-Error "Activity table definition not found: $activityPath"
}

# Create Threat table
$threatPath = Join-Path $scriptDir "ObsidianDatasharing_tableThreat.json"
if (Test-Path $threatPath) {
    $result2 = New-CustomTable -TableDefinitionPath $threatPath -WorkspaceResourceId $workspaceResourceId -Token $token
} else {
    Write-Error "Threat table definition not found: $threatPath"
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "   Table Creation Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next step: Run .\Deploy-Obsidian.ps1 to deploy the DCR" -ForegroundColor Cyan
Write-Host ""


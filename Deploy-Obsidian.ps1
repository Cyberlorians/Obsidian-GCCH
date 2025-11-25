<#
.SYNOPSIS
    Deploys Obsidian Security connector for GCCH (Azure Government)

.DESCRIPTION
    Deploys DCR with kind:Direct for Obsidian data ingestion.
    Tables are auto-created when data flows through the DCR.

.NOTES
    Requires: Az.Accounts, Az.Resources, Az.OperationalInsights modules
    Fill out config.json before running
#>

param(
    [string]$ConfigPath = ".\config.json"
)

$ErrorActionPreference = "Stop"

# Check required modules
Write-Host "Checking required modules..." -ForegroundColor Cyan
$requiredModules = @("Az.Accounts", "Az.Resources", "Az.OperationalInsights")
$missing = @()
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        $missing += $module
    }
}
if ($missing.Count -gt 0) {
    Write-Error "Missing required modules: $($missing -join ', ')`nInstall with: Install-Module $($missing -join ', ') -Scope CurrentUser"
    exit 1
}
Write-Host "[OK] Required modules present" -ForegroundColor Green

# Load config
Write-Host "Loading config..." -ForegroundColor Cyan
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config file not found: $ConfigPath"
    exit 1
}
try {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse config.json: $_"
    exit 1
}
Write-Host "[OK] Config loaded" -ForegroundColor Green

# Validate config
Write-Host "Validating config..." -ForegroundColor Cyan
if (-not $config.subscriptionId -or -not $config.resourceGroup -or -not $config.workspaceName) {
    Write-Error "Please fill out config.json with subscriptionId, resourceGroup, and workspaceName"
    exit 1
}
Write-Host "[OK] Config validated" -ForegroundColor Green

# Connect to Azure Government (non-interactive using config values)
Write-Host "Connecting to Azure Government..." -ForegroundColor Cyan
Write-Host "  Tenant: $($config.tenantId)"
Write-Host "  Subscription: $($config.subscriptionId)"
try {
    Connect-AzAccount -Environment AzureUSGovernment -TenantId $config.tenantId -SubscriptionId $config.subscriptionId -ErrorAction Stop | Out-Null
} catch {
    Write-Error "Failed to connect to Azure Government: $_"
    exit 1
}
Write-Host "[OK] Connected to Azure Government" -ForegroundColor Green

# Build workspace resource ID if not provided
Write-Host "Validating workspace..." -ForegroundColor Cyan
if (-not $config.workspaceResourceId) {
    try {
        $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $config.resourceGroup -Name $config.workspaceName -ErrorAction Stop
        $workspaceResourceId = $workspace.ResourceId
    } catch {
        Write-Error "Failed to find workspace '$($config.workspaceName)' in resource group '$($config.resourceGroup)': $_"
        exit 1
    }
} else {
    $workspaceResourceId = $config.workspaceResourceId
}
Write-Host "[OK] Workspace: $workspaceResourceId" -ForegroundColor Green

# Load original DCR and modify for GCCH
Write-Host "Loading DCR template..." -ForegroundColor Cyan
$dcrPath = Join-Path (Split-Path $ConfigPath) "ObsidianDatasharing_DCR.json"
if (-not (Test-Path $dcrPath)) {
    Write-Error "DCR file not found: $dcrPath"
    exit 1
}
try {
    $dcrFile = Get-Content $dcrPath -Raw | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse DCR file: $_"
    exit 1
}
Write-Host "[OK] DCR template loaded" -ForegroundColor Green

# Build ARM template with kind:Direct (no DCE needed)
$armTemplate = @{
    '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    resources = @(
        @{
            type = "Microsoft.Insights/dataCollectionRules"
            apiVersion = "2023-03-11"
            name = $config.dcrName
            location = $config.location
            kind = "Direct"
            properties = @{
                streamDeclarations = $dcrFile.properties.streamDeclarations
                destinations = @{
                    logAnalytics = @(
                        @{
                            workspaceResourceId = $workspaceResourceId
                            name = "law-destination"
                        }
                    )
                }
                dataFlows = @(
                    @{
                        streams = @("Custom-ObsidianActivity")
                        destinations = @("law-destination")
                        transformKql = "source"
                        outputStream = "Custom-ObsidianActivity_CL"
                    },
                    @{
                        streams = @("Custom-ObsidianThreat")
                        destinations = @("law-destination")
                        transformKql = "source"
                        outputStream = "Custom-ObsidianThreat_CL"
                    }
                )
            }
        }
    )
}

# Save and deploy
$templatePath = Join-Path (Split-Path $ConfigPath) "dcr-deploy.json"
try {
    $armTemplate | ConvertTo-Json -Depth 30 | Out-File $templatePath -Encoding utf8
} catch {
    Write-Error "Failed to save ARM template: $_"
    exit 1
}

Write-Host "Deploying DCR..." -ForegroundColor Cyan
try {
    $deployment = New-AzResourceGroupDeployment -ResourceGroupName $config.resourceGroup -TemplateFile $templatePath -Name "Obsidian-DCR-Deploy" -ErrorAction Stop
} catch {
    Write-Error "Deployment failed: $_"
    exit 1
}

if ($deployment.ProvisioningState -eq "Succeeded") {
    # Get DCR details
    try {
        $dcr = Get-AzResource -ResourceGroupName $config.resourceGroup -ResourceType "Microsoft.Insights/dataCollectionRules" -Name $config.dcrName -ApiVersion "2023-03-11" -ErrorAction Stop
    } catch {
        Write-Error "DCR deployed but failed to retrieve details: $_"
        exit 1
    }

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "       DEPLOYMENT SUCCESSFUL" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "DCR Name:            $($config.dcrName)"
    Write-Host "DCR Immutable ID:    $($dcr.Properties.immutableId)"
    Write-Host "Ingestion Endpoint:  $($dcr.Properties.endpoints.logsIngestion)"
    Write-Host ""
    Write-Host "Provide these to Obsidian:" -ForegroundColor Yellow
    Write-Host "  Tenant ID:           $($config.tenantId)"
    Write-Host "  App ID:              $($config.appId)"
    Write-Host "  App Secret:          <from your App Registration>"
    Write-Host "  DCR Immutable ID:    $($dcr.Properties.immutableId)"
    Write-Host "  Ingestion Endpoint:  $($dcr.Properties.endpoints.logsIngestion)"
    Write-Host ""
} else {
    Write-Error "Deployment failed with state: $($deployment.ProvisioningState)"
    exit 1
}
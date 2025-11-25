<#
.SYNOPSIS
    Deploy Obsidian Security Connector for GCCH
.DESCRIPTION
    Deploys all infrastructure needed for Obsidian Security to push data to Microsoft Sentinel in GCCH.
    Outputs credentials to provide to Obsidian for their push connector configuration.
    
    Uses config.json for configuration. Run the script and it will prompt for any missing values.
.PARAMETER ConfigPath
    Path to config.json file (default: config.json in same directory)
.EXAMPLE
    .\Deploy-ObsidianConnector.ps1
.EXAMPLE
    .\Deploy-ObsidianConnector.ps1 -ConfigPath "C:\path\to\config.json"
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json")
)

#region Prerequisites Check
Write-Host "Checking prerequisites..." -ForegroundColor Cyan

# Check for Az module
$azModule = Get-Module -ListAvailable -Name Az.Accounts
if (-not $azModule) {
    Write-Host "ERROR: Azure PowerShell module (Az) is not installed." -ForegroundColor Red
    Write-Host "Install it with: Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force" -ForegroundColor Yellow
    exit 1
}

# Check for required submodules
$requiredModules = @("Az.Accounts", "Az.Resources", "Az.OperationalInsights")
$missingModules = @()
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        $missingModules += $mod
    }
}

if ($missingModules.Count -gt 0) {
    Write-Host "ERROR: Missing required modules: $($missingModules -join ', ')" -ForegroundColor Red
    Write-Host "Install with: Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force" -ForegroundColor Yellow
    exit 1
}

Write-Host "  Az modules: OK" -ForegroundColor Green
#endregion

#region Configuration
function Get-ConfigValue {
    param($Config, $Section, $Key, $Prompt, $Required = $true, $Default = "")
    
    $value = $Config.$Section.$Key
    
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($Default) {
            $promptText = "$Prompt [$Default]"
        } else {
            $promptText = $Prompt
        }
        
        $value = Read-Host $promptText
        
        if ([string]::IsNullOrWhiteSpace($value) -and $Default) {
            $value = $Default
        }
        
        if ($Required -and [string]::IsNullOrWhiteSpace($value)) {
            Write-Host "Error: $Prompt is required." -ForegroundColor Red
            exit 1
        }
        
        # Update config object
        $Config.$Section.$Key = $value
    }
    
    return $value
}

# Load config
if (Test-Path $ConfigPath) {
    Write-Host "Loading configuration from: $ConfigPath" -ForegroundColor Cyan
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
} else {
    Write-Host "Config file not found. Creating new configuration..." -ForegroundColor Yellow
    $config = @{
        Azure = @{ SubscriptionId = ""; ResourceGroupName = ""; Location = "usgovvirginia" }
        Workspace = @{ Name = ""; ResourceGroupName = "" }
        AppRegistration = @{ DisplayName = "Obsidian-Sentinel-Connector" }
        DCR = @{ Name = "Obsidian-DCR-Direct" }
    } | ConvertTo-Json | ConvertFrom-Json
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host " Obsidian Security GCCH Connector Setup" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Press Enter to accept [default] values`n" -ForegroundColor Gray

# Prompt for missing values
$SubscriptionId = Get-ConfigValue -Config $config -Section "Azure" -Key "SubscriptionId" -Prompt "Azure Subscription ID"
$ResourceGroupName = Get-ConfigValue -Config $config -Section "Azure" -Key "ResourceGroupName" -Prompt "Resource Group for DCR"
$Location = Get-ConfigValue -Config $config -Section "Azure" -Key "Location" -Prompt "Azure Region" -Default "usgovvirginia"
$WorkspaceName = Get-ConfigValue -Config $config -Section "Workspace" -Key "Name" -Prompt "Log Analytics Workspace Name"
$WorkspaceResourceGroup = Get-ConfigValue -Config $config -Section "Workspace" -Key "ResourceGroupName" -Prompt "Workspace Resource Group (leave blank if same as DCR RG)" -Required $false
$AppDisplayName = Get-ConfigValue -Config $config -Section "AppRegistration" -Key "DisplayName" -Prompt "App Registration Name" -Default "Obsidian-Sentinel-Connector"
$DcrName = Get-ConfigValue -Config $config -Section "DCR" -Key "Name" -Prompt "DCR Name" -Default "Obsidian-DCR-Direct"

# Save updated config
$config | ConvertTo-Json -Depth 3 | Out-File $ConfigPath -Encoding UTF8
Write-Host "`nConfiguration saved to: $ConfigPath" -ForegroundColor Green

# Use WorkspaceResourceGroup or fall back to ResourceGroupName
if ([string]::IsNullOrWhiteSpace($WorkspaceResourceGroup)) {
    $WorkspaceResourceGroup = $ResourceGroupName
}

#endregion

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host " Starting Deployment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

$ErrorActionPreference = "Stop"

# Check Azure connection
$context = Get-AzContext
if (-not $context) {
    Write-Host "Not connected to Azure. Connecting to Azure Government..." -ForegroundColor Yellow
    Connect-AzAccount -Environment AzureUSGovernment
    $context = Get-AzContext
}

if ($context.Environment.Name -ne "AzureUSGovernment") {
    Write-Host "Switching to Azure Government cloud..." -ForegroundColor Yellow
    Connect-AzAccount -Environment AzureUSGovernment
}

# Set subscription
Write-Host "`n[1/6] Setting subscription..." -ForegroundColor Cyan
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
$tenantId = (Get-AzContext).Tenant.Id
Write-Host "  Subscription: $SubscriptionId" -ForegroundColor Green
Write-Host "  Tenant: $tenantId" -ForegroundColor Green

# Get workspace
Write-Host "`n[2/6] Getting workspace details..." -ForegroundColor Cyan
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $WorkspaceResourceGroup -Name $WorkspaceName
$workspaceResourceId = $workspace.ResourceId
Write-Host "  Workspace: $WorkspaceName" -ForegroundColor Green
Write-Host "  Resource ID: $workspaceResourceId" -ForegroundColor Green

# Create App Registration
Write-Host "`n[3/6] Creating App Registration..." -ForegroundColor Cyan
$existingApp = Get-AzADApplication -DisplayName $AppDisplayName -ErrorAction SilentlyContinue
if ($existingApp) {
    Write-Host "  App '$AppDisplayName' already exists. Creating new secret..." -ForegroundColor Yellow
    $app = $existingApp
} else {
    $app = New-AzADApplication -DisplayName $AppDisplayName
    Write-Host "  Created App: $AppDisplayName" -ForegroundColor Green
}

# Create Service Principal if needed
$sp = Get-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction SilentlyContinue
if (-not $sp) {
    $sp = New-AzADServicePrincipal -ApplicationId $app.AppId
    Write-Host "  Created Service Principal" -ForegroundColor Green
} else {
    Write-Host "  Service Principal exists" -ForegroundColor Green
}

# Create client secret
$secret = New-AzADAppCredential -ObjectId $app.Id -EndDate (Get-Date).AddYears(2)
$clientSecret = $secret.SecretText
Write-Host "  Created client secret (expires: $($secret.EndDateTime))" -ForegroundColor Green

# Create custom tables
Write-Host "`n[4/6] Creating custom tables..." -ForegroundColor Cyan

$activityColumns = @{
    TimeGenerated = "datetime"
    EventMessage = "string"
    EventOriginalType = "string"
    EventType = "string"
    EventResult = "string"
    EventSchemaVersion = "string"
    EventOwner = "string"
    EventProduct = "string"
    EventVendor = "string"
    EventSchema = "string"
    ActorUserId = "string"
    ActorUsername = "string"
    ActorUserType = "string"
    ActorEmail = "string"
    ActingAppName = "string"
    Application = "string"
    Object = "string"
    ObjectId = "string"
    ObjectName = "string"
    ObjectType = "string"
    Operation = "string"
    SrcIpAddr = "string"
    SrcGeoCity = "string"
    SrcGeoCountry = "string"
    SrcGeoRegion = "string"
    TargetUserId = "string"
    TargetUsername = "string"
    HttpUserAgent = "string"
    SessionId = "string"
    AdditionalFields = "dynamic"
    SourceSystem = "string"
}

$threatColumns = @{
    TimeGenerated = "datetime"
    AlertLink = "string"
    AlertName = "string"
    AlertOriginalSeverity = "string"
    AlertSeverity = "string"
    AlertStatus = "string"
    AlertType = "string"
    AlertSubType = "string"
    AlertVerdict = "string"
    AttackTactics = "dynamic"
    AttackTechniques = "dynamic"
    CompromisedEntity = "string"
    ConfidenceLevel = "string"
    Description = "string"
    DetectionMethod = "string"
    Entities = "dynamic"
    EventCount = "int"
    EventEndTime = "datetime"
    EventMessage = "string"
    EventOriginalType = "string"
    EventOwner = "string"
    EventProduct = "string"
    EventVendor = "string"
    EventSchema = "string"
    EventSchemaVersion = "string"
    EventStartTime = "datetime"
    EventType = "string"
    EventUid = "string"
    ProductName = "string"
    ProviderName = "string"
    RemediationSteps = "dynamic"
    SystemAlertId = "string"
    ThreatCategory = "string"
    ThreatId = "string"
    ThreatName = "string"
    ThreatRiskLevel = "int"
    VendorName = "string"
    VendorOriginalId = "string"
    ActorUserId = "string"
    ActorUsername = "string"
    TargetUserId = "string"
    TargetUsername = "string"
    AdditionalFields = "dynamic"
    SourceSystem = "string"
}

# Create Activity table
$existingActivity = Get-AzOperationalInsightsTable -ResourceGroupName $WorkspaceResourceGroup -WorkspaceName $WorkspaceName -TableName "ObsidianActivity_CL" -ErrorAction SilentlyContinue
if (-not $existingActivity) {
    New-AzOperationalInsightsTable -ResourceGroupName $WorkspaceResourceGroup -WorkspaceName $WorkspaceName -TableName "ObsidianActivity_CL" -Column $activityColumns -Plan "Analytics" -RetentionInDays 90 | Out-Null
    Write-Host "  Created ObsidianActivity_CL" -ForegroundColor Green
} else {
    Write-Host "  ObsidianActivity_CL already exists" -ForegroundColor Yellow
}

# Create Threat table
$existingThreat = Get-AzOperationalInsightsTable -ResourceGroupName $WorkspaceResourceGroup -WorkspaceName $WorkspaceName -TableName "ObsidianThreat_CL" -ErrorAction SilentlyContinue
if (-not $existingThreat) {
    New-AzOperationalInsightsTable -ResourceGroupName $WorkspaceResourceGroup -WorkspaceName $WorkspaceName -TableName "ObsidianThreat_CL" -Column $threatColumns -Plan "Analytics" -RetentionInDays 90 | Out-Null
    Write-Host "  Created ObsidianThreat_CL" -ForegroundColor Green
} else {
    Write-Host "  ObsidianThreat_CL already exists" -ForegroundColor Yellow
}

# Deploy DCR
Write-Host "`n[5/6] Deploying Data Collection Rule..." -ForegroundColor Cyan

$templatePath = Join-Path $PSScriptRoot "azuredeploy.json"

$deployment = New-AzResourceGroupDeployment `
    -ResourceGroupName $ResourceGroupName `
    -TemplateFile $templatePath `
    -workspaceResourceId $workspaceResourceId `
    -location $Location `
    -dcrName $DcrName `
    -ErrorAction Stop

$dcrId = $deployment.Outputs.dcrId.Value
$immutableId = $deployment.Outputs.immutableId.Value
$logsEndpoint = $deployment.Outputs.logsIngestionEndpoint.Value

Write-Host "  DCR deployed: $DcrName" -ForegroundColor Green
Write-Host "  Immutable ID: $immutableId" -ForegroundColor Green
Write-Host "  Endpoint: $logsEndpoint" -ForegroundColor Green

# Assign RBAC
Write-Host "`n[6/6] Assigning RBAC permissions..." -ForegroundColor Cyan
$roleId = "3913510d-42f4-4e42-8a64-420c390055eb"  # Monitoring Metrics Publisher

try {
    New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionId $roleId -Scope $dcrId -ErrorAction Stop | Out-Null
    Write-Host "  Assigned Monitoring Metrics Publisher role" -ForegroundColor Green
} catch {
    if ($_.Exception.Message -like "*Conflict*") {
        Write-Host "  Role assignment already exists" -ForegroundColor Yellow
    } else {
        throw
    }
}

# Output credentials
Write-Host "`n" -NoNewline
Write-Host "============================================" -ForegroundColor Green
Write-Host " DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host "`nProvide these values to Obsidian Security:" -ForegroundColor Cyan
Write-Host "--------------------------------------------" -ForegroundColor Gray

$output = @"

Tenant ID (Directory ID)
$tenantId

Application (Client) ID
$($app.AppId)

Client Secret
$clientSecret

Data Collection Endpoint URI
$logsEndpoint

Data Collection Rule Immutable ID
$immutableId

Activity Stream Name
Custom-ObsidianActivity

Threat Stream Name
Custom-ObsidianThreat

"@

Write-Host $output -ForegroundColor Yellow

Write-Host "--------------------------------------------" -ForegroundColor Gray
Write-Host "IMPORTANT: Save the Client Secret now - it cannot be retrieved later!" -ForegroundColor Red
Write-Host "============================================`n" -ForegroundColor Green

# Save to file
$outputFile = Join-Path $PSScriptRoot "ObsidianCredentials_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$output | Out-File -FilePath $outputFile -Encoding UTF8
Write-Host "Credentials saved to: $outputFile" -ForegroundColor Cyan


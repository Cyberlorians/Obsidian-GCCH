# Obsidian Security Connector for Microsoft Sentinel (GCCH)

Deploy Obsidian Security data connector infrastructure to Microsoft Sentinel in **Azure Government (GCCH)**.

## Overview

This package deploys the required Azure resources for Obsidian Security to push activity and threat data to your Microsoft Sentinel workspace.

**Once deployed, provide the generated credentials to Obsidian Security to configure their push connector.**

---

## Architecture

```
┌──────────────────────────┐
│  Obsidian Security       │
│  Platform                │
└───────────┬──────────────┘
            │
            │  Push via Logs Ingestion API
            │  (Bearer Token Auth)
            ▼
┌──────────────────────────┐
│  Data Collection Rule    │
│  (kind: Direct)          │
│  - No DCE required       │
│  - Embedded endpoint     │
└───────────┬──────────────┘
            │
            ▼
┌──────────────────────────┐
│  Log Analytics Workspace │
│  ┌────────────────────┐  │
│  │ ObsidianActivity_CL│  │
│  │ ObsidianThreat_CL  │  │
│  └────────────────────┘  │
└───────────┬──────────────┘
            │
            ▼
┌──────────────────────────┐
│   Microsoft Sentinel     │
└──────────────────────────┘
```

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **Azure PowerShell** | Az module installed ([Install Guide](https://docs.microsoft.com/powershell/azure/install-az-ps)) |
| **Azure Government** | Active subscription |
| **Permissions** | App Registration, Log Analytics tables, DCR deployment, RBAC assignment |
| **Sentinel** | Enabled on target Log Analytics workspace |

---

## Quick Start

### 1. Edit Configuration

Edit `config.json` with your environment details:

```json
{
    "Azure": {
        "SubscriptionId": "your-subscription-id",
        "ResourceGroupName": "your-resource-group",
        "Location": "usgovvirginia"
    },
    "Workspace": {
        "Name": "your-sentinel-workspace",
        "ResourceGroupName": "workspace-resource-group"
    },
    "AppRegistration": {
        "DisplayName": "Obsidian-Sentinel-Connector"
    },
    "DCR": {
        "Name": "Obsidian-DCR-Direct"
    }
}
```

> **Note:** Leave `Workspace.ResourceGroupName` blank if same as `Azure.ResourceGroupName`

### 2. Run Deployment

```powershell
.\Deploy-ObsidianConnector.ps1
```

The script will:
- Validate prerequisites (Az modules)
- Prompt for any missing config values
- Deploy all resources
- Output credentials for Obsidian

---

## What Gets Deployed

| Resource | Description |
|----------|-------------|
| **App Registration** | Entra ID application for authentication |
| **Service Principal** | Identity with Monitoring Metrics Publisher role |
| **Client Secret** | 2-year credential (save securely!) |
| **ObsidianActivity_CL** | Custom table for activity/audit events |
| **ObsidianThreat_CL** | Custom table for threat/alert events |
| **Data Collection Rule** | DCR (kind: Direct) with embedded ingestion endpoint |

---

## Deployment Output

After successful deployment, you will receive:

| Parameter | Description |
|-----------|-------------|
| Tenant ID | Your Azure AD tenant ID |
| Application (Client) ID | App registration ID |
| Client Secret | **Save immediately - cannot be retrieved later** |
| Data Collection Endpoint URI | GCCH ingestion endpoint |
| Data Collection Rule Immutable ID | DCR identifier |
| Activity Stream Name | `Custom-ObsidianActivity` |
| Threat Stream Name | `Custom-ObsidianThreat` |

**Provide these values to Obsidian Security to configure their push connector.**

Credentials are also saved to `ObsidianCredentials_<timestamp>.txt`

---

## Verify Data Flow

After Obsidian configures their connector, run this KQL query:

```kql
union ObsidianActivity_CL, ObsidianThreat_CL
| project TimeGenerated, Type, EventMessage, EventType
| order by TimeGenerated desc
| take 50
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| **Az module not found** | `Install-Module -Name Az -Scope CurrentUser -Force` |
| **Not connected to GCCH** | `Connect-AzAccount -Environment AzureUSGovernment` |
| **Tables already exist** | Expected on redeployment - script skips existing tables |
| **Data not appearing** | Allow 5-15 minutes; verify credentials with Obsidian |

---

## Files

| File | Purpose |
|------|---------|
| `Deploy-ObsidianConnector.ps1` | Main deployment script |
| `config.json` | Configuration (edit before running) |
| `azuredeploy.json` | ARM template for DCR |

---



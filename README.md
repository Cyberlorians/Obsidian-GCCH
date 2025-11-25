# Obsidian Security Connector for Microsoft Sentinel (GCCH)

Deploy Obsidian Security data connector for Azure Government (GCCH) environments.

## Prerequisites

- Azure Government subscription with Microsoft Sentinel enabled
- Log Analytics workspace
- PowerShell with Az modules installed:
  - `Az.Accounts`
  - `Az.Resources`
  - `Az.OperationalInsights`
- Permissions to create App Registrations and assign roles

## Files

| File | Description |
|------|-------------|
| `config.template.json` | Configuration template - copy to `config.json` |
| `Create-Tables.ps1` | Creates custom Log Analytics tables |
| `Deploy-Obsidian.ps1` | Deploys the Data Collection Rule (DCR) |
| `ObsidianDatasharing_tableActivity.json` | Schema for ObsidianActivity_CL table |
| `ObsidianDatasharing_tableThreat.json` | Schema for ObsidianThreat_CL table |
| `ObsidianDatasharing_DCR.json` | DCR template with stream declarations |

## Deployment Steps

### Step 1: Create App Registration

1. Go to **Azure Portal** > **Microsoft Entra ID** > **App registrations**
2. Click **New registration**
   - Name: `Obsidian-Sentinel-Connector` (or similar)
   - Supported account types: **Single tenant**
3. After creation, note the **Application (client) ID**
4. Go to **Certificates & secrets** > **New client secret**
   - Description: `Obsidian connector`
   - Expiration: Choose appropriate duration
5. **Copy the secret value immediately** (it won't be shown again)

### Step 2: Configure

1. Copy the template to create your config:
   ```powershell
   Copy-Item config.template.json config.json
   ```

2. Edit `config.json` with your values:
   ```json
   {
     "tenantId": "your-tenant-id",
     "subscriptionId": "your-subscription-id",
     "resourceGroup": "your-resource-group",
     "workspaceName": "your-workspace-name",
     "workspaceResourceId": "",
     "location": "usgovvirginia",
     "dcrName": "ObsidianDatasharingDCR",
     "appId": "app-registration-client-id",
     "appSecret": "app-registration-secret"
   }
   ```

   | Field | Description |
   |-------|-------------|
   | `tenantId` | Your Azure AD tenant ID |
   | `subscriptionId` | Azure subscription containing the Log Analytics workspace |
   | `resourceGroup` | Resource group where the DCR will be created |
   | `workspaceName` | Name of your Log Analytics workspace |
   | `workspaceResourceId` | (Optional) Full resource ID of workspace - auto-detected if blank |
   | `location` | Azure region - use `usgovvirginia` or `usgovarizona` for GCCH |
   | `dcrName` | Name for the Data Collection Rule |
   | `appId` | Application (client) ID from Step 1 |
   | `appSecret` | Client secret from Step 1 |

### Step 3: Create Tables

```powershell
.\Create-Tables.ps1
```

This creates the custom tables in your Log Analytics workspace:
- `ObsidianActivity_CL` - Activity/audit events
- `ObsidianThreat_CL` - Security alerts and threats

### Step 4: Deploy DCR

```powershell
.\Deploy-Obsidian.ps1
```

This deploys the Data Collection Rule and outputs:
- **DCR Immutable ID**
- **Ingestion Endpoint**

### Step 5: Assign Role to App Registration

After the DCR is deployed, assign the **Monitoring Metrics Publisher** role to your App Registration:

```powershell
$config = Get-Content .\config.json | ConvertFrom-Json
$dcr = Get-AzResource -ResourceGroupName $config.resourceGroup `
    -ResourceType "Microsoft.Insights/dataCollectionRules" `
    -Name $config.dcrName -ApiVersion "2023-03-11"

New-AzRoleAssignment -ApplicationId $config.appId `
    -RoleDefinitionName "Monitoring Metrics Publisher" `
    -Scope $dcr.ResourceId
```

### Step 6: Provide Details to Obsidian

Send the following to Obsidian Security:

| Field | Value |
|-------|-------|
| Tenant ID | From config.json |
| App ID | From config.json |
| App Secret | From config.json |
| DCR Immutable ID | From Deploy-Obsidian.ps1 output |
| Ingestion Endpoint | From Deploy-Obsidian.ps1 output |

## Troubleshooting

### "InvalidAuthenticationToken" Error
The Az.Accounts module returns tokens as SecureString in newer versions. The scripts handle this automatically.

### "Forbidden" Error When Sending Data
Ensure the **Monitoring Metrics Publisher** role is assigned to the App Registration (not your user account) on the DCR resource.

### Tables Not Appearing
Wait a few minutes after running Create-Tables.ps1. Tables are created asynchronously.

### Data Not Appearing
- Verify role assignment is complete (can take up to 15 minutes to propagate)
- Check the App Secret hasn't expired

## Security Notes

- Store `config.json` securely - it contains the app secret
- Do not commit `config.json` to source control
- Consider using Azure Key Vault for production secret management
- Rotate the app secret periodically

## Support

For issues with:
- **This deployment**: Check Azure Activity Log and DCR metrics
- **Obsidian data**: Contact Obsidian Security support

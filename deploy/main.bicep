// Specialized Bicycles MCP server — Azure Functions (Linux, Python) deployment.
//
// Design notes:
// * Tool 2 (`design_custom_bikes`) runs as an in-process MCP Task for ~300s.
//   The task state and background worker live INSIDE the single Function App
//   worker process (FastMCP `memory://` backend), so the plan MUST keep one
//   instance always running:
//     - Dedicated (App Service) plan with `alwaysOn = true`
//     - `functionAppScaleLimit = 1` (no scale-out; the in-memory task store is
//       per-process and would be inconsistent across instances)
//   A Consumption plan is intentionally NOT used (cold-start / scale-out would
//   break long-running in-process tasks).

@description('Base name used to derive resource names. Lowercase letters/numbers.')
@minLength(3)
@maxLength(20)
param appName string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Python version for the Linux Functions runtime.')
@allowed([
  '3.11'
  '3.12'
])
param pythonVersion string = '3.12'

@description('Tool 1 response delay in seconds (spec default 20).')
param tool1DelaySeconds int = 20

@description('Tool 2 (MCP task) response delay in seconds (spec default 300).')
param tool2DelaySeconds int = 300

var suffix = uniqueString(resourceGroup().id, appName)
var storageAccountName = toLower(take('${replace(appName, '-', '')}${suffix}', 24))
var planName = '${appName}-plan'
var functionAppName = '${appName}-${take(suffix, 6)}'
var appInsightsName = '${appName}-ai'

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

// Dedicated (App Service) plan so we can enable Always-On + a single instance.
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  sku: {
    name: 'B1'
    tier: 'Basic'
  }
  kind: 'linux'
  properties: {
    reserved: true // Linux
  }
}

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storage.listKeys().keys[0].value}'

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    // Single instance: the in-process MCP task worker is per-process.
    siteConfig: {
      linuxFxVersion: 'Python|${pythonVersion}'
      alwaysOn: true
      functionAppScaleLimit: 1
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: storageConnectionString
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: storageConnectionString
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(functionAppName)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          // Long ASGI/streaming requests should not be recycled mid-flight.
          name: 'PYTHON_ENABLE_INIT_INDEXING'
          value: '1'
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        {
          name: 'ENABLE_ORYX_BUILD'
          value: 'true'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'BIKES_TOOL_1_DELAY_SECONDS'
          value: string(tool1DelaySeconds)
        }
        {
          name: 'BIKES_TOOL_2_DELAY_SECONDS'
          value: string(tool2DelaySeconds)
        }
      ]
    }
  }
}

output functionAppName string = functionApp.name
output baseUrl string = 'https://${functionApp.properties.defaultHostName}'
output healthUrl string = 'https://${functionApp.properties.defaultHostName}/health'
output mcpUrl string = 'https://${functionApp.properties.defaultHostName}/mcp'

// Front-door for the Specialized Bicycles MCP server:
//
//     MCP client ──► Application Gateway ──► API Management ──► Function App
//
// Everything is anonymous and public end-to-end (no subscription keys, no
// function keys, no private networking required between the hops). The chain
// is provisioned so that the **long-running MCP tool** (`design_custom_bikes`,
// ~300s) keeps working through both gateways:
//
//   * Application Gateway: the backend HTTP settings use a very large
//     `requestTimeout` so a long-lived Streamable-HTTP / SSE connection is not
//     reset mid-flight. (App Gateway's default is only ~30s.)
//   * API Management: the API policy forwards the request with
//     `buffer-response="false"` so Server-Sent Events are streamed straight
//     through instead of being buffered, and uses the maximum honored
//     `forward-request` timeout.
//
// The Function App itself is unchanged (deploy/main.bicep) — it still serves
// the `/mcp` Streamable HTTP endpoint and `/health` with anonymous auth. The
// MCP Tasks pattern (SEP-1686) means the long tool returns a task id quickly
// and the client polls for the result, so each individual HTTP hop stays well
// under any hard limit while the SSE channel streams notifications.

@description('Base name used to derive resource names. Lowercase letters/numbers.')
@minLength(3)
@maxLength(20)
param appName string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Public default host name of the already-deployed Function App, e.g. myapp.azurewebsites.net (no scheme, no trailing slash).')
param functionAppHostName string

@description('APIM publisher e-mail (required by API Management).')
param publisherEmail string = 'admin@example.com'

@description('APIM publisher organisation name (required by API Management).')
param publisherName string = 'Specialized Bikes MCP'

@description('APIM SKU. Developer is the cheapest dedicated tier that streams SSE and supports long-running calls; Consumption is intentionally avoided.')
@allowed([
  'Developer'
  'Basic'
  'Standard'
  'Premium'
])
param apimSku string = 'Developer'

@description('Backend (App Gateway -> APIM, APIM -> Function App) idle request timeout in seconds. Must comfortably exceed the longest streaming hop so long-running tools are not cut off.')
@minValue(60)
@maxValue(86400)
param backendRequestTimeoutSeconds int = 3600

var suffix = uniqueString(resourceGroup().id, appName)
var apimName = '${appName}-apim-${take(suffix, 6)}'
var vnetName = '${appName}-vnet'
var agwSubnetName = 'appgw-subnet'
var pipName = '${appName}-agw-pip'
var agwName = '${appName}-agw'

var apimGatewayHost = '${apimName}.azure-api.net'

// ── Network for the Application Gateway ──────────────────────────────────────
// App Gateway v2 requires a dedicated subnet. APIM stays public (External /
// virtualNetworkType None), so no private wiring is needed for the APIM hop.
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: agwSubnetName
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: pipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// ── API Management ───────────────────────────────────────────────────────────
resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: apimName
  location: location
  sku: {
    name: apimSku
    capacity: 1
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    // Public, no private networking between the hops.
    virtualNetworkType: 'None'
  }
}

// MCP API: a thin, anonymous pass-through to the Function App. `path` is empty
// so the public routes (/mcp, /health) are preserved exactly through APIM.
resource mcpApi 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'bikes-mcp'
  properties: {
    displayName: 'Specialized Bikes MCP'
    apiRevision: '1'
    path: ''
    protocols: [
      'https'
    ]
    // Anonymous + public: no subscription key required.
    subscriptionRequired: false
    serviceUrl: 'https://${functionAppHostName}'
  }
}

// API-level policy: stream SSE straight through (no buffering) and forward with
// a generous timeout so long-running MCP tools survive the APIM hop.
resource mcpApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = {
  parent: mcpApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '''<policies>
  <inbound>
    <base />
    <cors allow-credentials="false">
      <allowed-origins>
        <origin>*</origin>
      </allowed-origins>
      <allowed-methods>
        <method>GET</method>
        <method>POST</method>
        <method>DELETE</method>
        <method>OPTIONS</method>
      </allowed-methods>
      <allowed-headers>
        <header>*</header>
      </allowed-headers>
      <expose-headers>
        <header>*</header>
      </expose-headers>
    </cors>
  </inbound>
  <backend>
    <!-- buffer-response="false" => stream Server-Sent Events to the client.
         The forward-request timeout is fixed at 240s, the maximum APIM honors
         (values above 240s are ignored), independent of the App Gateway
         backendRequestTimeoutSeconds. The MCP Tasks pattern keeps each
         request/response short while the SSE channel streams notifications. -->
    <forward-request buffer-response="false" timeout="240" />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>'''
  }
}

// Streamable HTTP transport uses GET (SSE stream), POST (messages) and DELETE
// (session teardown) on /mcp, plus the GET /health probe.
resource opMcpPost 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: mcpApi
  name: 'mcp-post'
  properties: {
    displayName: 'MCP messages (POST)'
    method: 'POST'
    urlTemplate: '/mcp'
  }
}

resource opMcpGet 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: mcpApi
  name: 'mcp-get'
  properties: {
    displayName: 'MCP SSE stream (GET)'
    method: 'GET'
    urlTemplate: '/mcp'
  }
}

resource opMcpDelete 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: mcpApi
  name: 'mcp-delete'
  properties: {
    displayName: 'MCP session teardown (DELETE)'
    method: 'DELETE'
    urlTemplate: '/mcp'
  }
}

resource opHealth 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: mcpApi
  name: 'health-get'
  properties: {
    displayName: 'Health probe (GET)'
    method: 'GET'
    urlTemplate: '/health'
  }
}

// ── Application Gateway (Standard_v2) ────────────────────────────────────────
// Public front door. Forwards everything to APIM over HTTPS with a large
// requestTimeout so long-lived streaming connections are not reset.
var agwId = resourceId('Microsoft.Network/applicationGateways', agwName)

resource appGateway 'Microsoft.Network/applicationGateways@2023-11-01' = {
  name: agwName
  location: location
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
      capacity: 1
    }
    gatewayIPConfigurations: [
      {
        name: 'appgw-ipcfg'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/${agwSubnetName}'
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appgw-frontend'
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port80'
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'apim-pool'
        properties: {
          backendAddresses: [
            {
              fqdn: apimGatewayHost
            }
          ]
        }
      }
    ]
    probes: [
      {
        name: 'apim-probe'
        properties: {
          protocol: 'Https'
          // APIM's anonymous health endpoint (returns 200 without a key).
          path: '/status-0123456789abcdef'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'apim-https'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          // Large timeout keeps long-running / streaming MCP calls alive.
          requestTimeout: backendRequestTimeoutSeconds
          probe: {
            id: '${agwId}/probes/apim-probe'
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'http-listener'
        properties: {
          frontendIPConfiguration: {
            id: '${agwId}/frontendIPConfigurations/appgw-frontend'
          }
          frontendPort: {
            id: '${agwId}/frontendPorts/port80'
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'route-all'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: '${agwId}/httpListeners/http-listener'
          }
          backendAddressPool: {
            id: '${agwId}/backendAddressPools/apim-pool'
          }
          backendHttpSettings: {
            id: '${agwId}/backendHttpSettingsCollection/apim-https'
          }
        }
      }
    ]
  }
  dependsOn: [
    apim
  ]
}

output apimName string = apim.name
output apimGatewayUrl string = 'https://${apimGatewayHost}'
output appGatewayPublicIp string = publicIp.properties.ipAddress
output baseUrl string = 'http://${publicIp.properties.ipAddress}'
output mcpUrl string = 'http://${publicIp.properties.ipAddress}/mcp'
output healthUrl string = 'http://${publicIp.properties.ipAddress}/health'

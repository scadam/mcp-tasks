#!/usr/bin/env bash
#
# Deploy the public front door for the Specialized Bicycles MCP server:
#
#     MCP client ──► Application Gateway ──► API Management ──► Function App
#
# This provisions deploy/gateway.bicep (VNet + Public IP + Application Gateway
# Standard_v2 + API Management) in front of an ALREADY-DEPLOYED Function App,
# then waits for the Application Gateway endpoint to come up and runs the
# deployment smoke tests through the gateway.
#
# Everything is anonymous and public end-to-end, and the timeouts/streaming
# config support the long-running MCP task (`design_custom_bikes`).
#
# Usage:
#   ./deploy/deploy-gateway.sh -g <resource-group> [-f <func-host>] [-l <location>] [-n <app-name>]
#
#   -g  Resource group that already contains the Function App (required).
#   -f  Function App default host name (e.g. myapp.azurewebsites.net).
#       If omitted, it is auto-discovered from the resource group.
#   -l  Azure location (default: resource group's location).
#   -n  Base name used to derive gateway/APIM resource names (default: bikesmcp).
#   -e  APIM publisher e-mail (default: admin@example.com).
#   -T  Skip the post-deploy smoke tests.
#
# Requirements: az CLI (logged in), python3.
set -euo pipefail

RESOURCE_GROUP=""
FUNCTION_HOST=""
LOCATION=""
APP_NAME="bikesmcp"
PUBLISHER_EMAIL="admin@example.com"
RUN_TESTS="true"

usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '2,30p'
  exit "${1:-0}"
}

while getopts "g:f:l:n:e:Th" opt; do
  case "$opt" in
    g) RESOURCE_GROUP="$OPTARG" ;;
    f) FUNCTION_HOST="$OPTARG" ;;
    l) LOCATION="$OPTARG" ;;
    n) APP_NAME="$OPTARG" ;;
    e) PUBLISHER_EMAIL="$OPTARG" ;;
    T) RUN_TESTS="false" ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done

[[ -n "$RESOURCE_GROUP" ]] || { echo "ERROR: -g <resource-group> is required"; usage 1; }
command -v az >/dev/null || { echo "ERROR: az CLI not found"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Resolve location + function host ─────────────────────────────────────────
if [[ -z "$LOCATION" ]]; then
  LOCATION="$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)"
fi

if [[ -z "$FUNCTION_HOST" ]]; then
  echo "==> Auto-discovering Function App in $RESOURCE_GROUP..."
  FUNC_NAME="$(az functionapp list --resource-group "$RESOURCE_GROUP" \
    --query "[0].name" -o tsv)"
  [[ -n "$FUNC_NAME" ]] || { echo "ERROR: no Function App found in $RESOURCE_GROUP; pass -f"; exit 1; }
  FUNCTION_HOST="$(az functionapp show --resource-group "$RESOURCE_GROUP" \
    --name "$FUNC_NAME" --query defaultHostName -o tsv)"
fi

echo "==> Bikes MCP — App Gateway + APIM front door"
echo "    Resource group : $RESOURCE_GROUP"
echo "    Location       : $LOCATION"
echo "    App name       : $APP_NAME"
echo "    Function host  : $FUNCTION_HOST"

# ── Deploy gateway infrastructure (Bicep) ────────────────────────────────────
# Note: provisioning API Management can take 30-45 minutes.
echo "==> Deploying gateway infrastructure (Bicep) — APIM can take ~40 min..."
DEPLOY_OUT="$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$SCRIPT_DIR/gateway.bicep" \
  --parameters appName="$APP_NAME" location="$LOCATION" \
               functionAppHostName="$FUNCTION_HOST" \
               publisherEmail="$PUBLISHER_EMAIL" \
  --query properties.outputs --output json)"

BASE_URL="$(echo "$DEPLOY_OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["baseUrl"]["value"])')"
HEALTH_URL="$(echo "$DEPLOY_OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["healthUrl"]["value"])')"
MCP_URL="$(echo "$DEPLOY_OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["mcpUrl"]["value"])')"
APIM_URL="$(echo "$DEPLOY_OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["apimGatewayUrl"]["value"])')"

echo "    APIM URL       : $APIM_URL"
echo "    Gateway base   : $BASE_URL"

# ── Wait for health through the gateway ──────────────────────────────────────
echo "==> Waiting for /health through the Application Gateway..."
ok="false"
for _ in $(seq 1 30); do
  if curl -fsS --max-time 10 "$HEALTH_URL" >/dev/null 2>&1; then
    ok="true"; break
  fi
  sleep 10
done
if [[ "$ok" != "true" ]]; then
  echo "ERROR: health endpoint did not become ready through the gateway: $HEALTH_URL"
  exit 1
fi
echo "    Healthy: $HEALTH_URL"

# ── Smoke tests through the gateway ──────────────────────────────────────────
if [[ "$RUN_TESTS" == "true" ]]; then
  echo "==> Running deployment smoke tests through the gateway ($BASE_URL)..."
  ( cd "$PROJECT_ROOT" \
    && python3 -m pip install --quiet --disable-pip-version-check \
         "fastmcp" "httpx" "pytest" "pytest-asyncio" \
    && MCP_BASE_URL="$BASE_URL" MCP_SMOKE_FAST=1 \
       python3 -m pytest tests/test_deployment.py -q )
fi

echo ""
echo "==> Front-door deployment complete."
echo "    Health : $HEALTH_URL"
echo "    MCP    : $MCP_URL"
echo ""
echo "    Path: MCP client -> Application Gateway -> APIM -> Function App"

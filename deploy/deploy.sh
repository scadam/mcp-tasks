#!/usr/bin/env bash
#
# One-click deployment for the Specialized Bicycles MCP server.
#
# Creates a brand-new resource group, provisions the infrastructure with Bicep
# (deploy/main.bicep), publishes the Function App code, and then runs the
# deployment smoke tests against the live endpoint.
#
# Usage:
#   ./deploy/deploy.sh [-g <resource-group>] [-l <location>] [-n <app-name>]
#
# Defaults are generated so the script can be run with no arguments at all:
#   ./deploy/deploy.sh
#
# Requirements: az CLI (logged in), Azure Functions Core Tools (func), python3.
set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
RAND="$(date +%s | tail -c 6 | head -c 5)"
RESOURCE_GROUP="rg-bikes-mcp-${RAND}"
LOCATION="eastus"
APP_NAME="bikesmcp${RAND}"
RUN_TESTS="true"
# Use fast delays for the post-deploy smoke test by default so a one-click run
# doesn't block for 5 minutes. Set to the spec values for a "real" deployment.
TOOL1_DELAY="${BIKES_TOOL_1_DELAY_SECONDS:-20}"
TOOL2_DELAY="${BIKES_TOOL_2_DELAY_SECONDS:-300}"

usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '2,15p'
  exit "${1:-0}"
}

while getopts "g:l:n:1:2:Th" opt; do
  case "$opt" in
    g) RESOURCE_GROUP="$OPTARG" ;;
    l) LOCATION="$OPTARG" ;;
    n) APP_NAME="$OPTARG" ;;
    1) TOOL1_DELAY="$OPTARG" ;;
    2) TOOL2_DELAY="$OPTARG" ;;
    T) RUN_TESTS="false" ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> Specialized Bicycles MCP — one-click deploy"
echo "    Resource group : $RESOURCE_GROUP"
echo "    Location       : $LOCATION"
echo "    App name       : $APP_NAME"
echo "    Tool delays    : ${TOOL1_DELAY}s / ${TOOL2_DELAY}s"

command -v az >/dev/null || { echo "ERROR: az CLI not found"; exit 1; }
command -v func >/dev/null || { echo "ERROR: Azure Functions Core Tools (func) not found"; exit 1; }

# ── 1. Resource group ───────────────────────────────────────────────────────
echo "==> Creating resource group..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

# ── 2. Infrastructure (Bicep) ───────────────────────────────────────────────
echo "==> Deploying infrastructure (Bicep)..."
DEPLOY_OUT="$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$SCRIPT_DIR/main.bicep" \
  --parameters appName="$APP_NAME" location="$LOCATION" \
               tool1DelaySeconds="$TOOL1_DELAY" tool2DelaySeconds="$TOOL2_DELAY" \
  --query properties.outputs --output json)"

FUNCTION_APP_NAME="$(echo "$DEPLOY_OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["functionAppName"]["value"])')"
BASE_URL="$(echo "$DEPLOY_OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["baseUrl"]["value"])')"
HEALTH_URL="$(echo "$DEPLOY_OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["healthUrl"]["value"])')"
MCP_URL="$(echo "$DEPLOY_OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["mcpUrl"]["value"])')"

echo "    Function App   : $FUNCTION_APP_NAME"
echo "    Base URL       : $BASE_URL"

# ── 3. Publish code ─────────────────────────────────────────────────────────
echo "==> Publishing Function App code (remote build)..."
( cd "$PROJECT_ROOT" && func azure functionapp publish "$FUNCTION_APP_NAME" --python --build remote )

# ── 4. Wait for health ──────────────────────────────────────────────────────
echo "==> Waiting for /health to come up..."
ok="false"
for i in $(seq 1 30); do
  if curl -fsS --max-time 10 "$HEALTH_URL" >/dev/null 2>&1; then
    ok="true"; break
  fi
  sleep 10
done
if [[ "$ok" != "true" ]]; then
  echo "ERROR: health endpoint did not become ready: $HEALTH_URL"
  exit 1
fi
echo "    Healthy: $HEALTH_URL"

# ── 5. Smoke tests ──────────────────────────────────────────────────────────
if [[ "$RUN_TESTS" == "true" ]]; then
  echo "==> Running deployment smoke tests against $BASE_URL ..."
  ( cd "$PROJECT_ROOT" \
    && python3 -m pip install --quiet --disable-pip-version-check \
         "fastmcp" "httpx" "pytest" "pytest-asyncio" \
    && MCP_BASE_URL="$BASE_URL" MCP_TASK_TIMEOUT_SECONDS="$((TOOL2_DELAY + 60))" \
       python3 -m pytest tests/test_deployment.py -q )
fi

echo ""
echo "==> Deployment complete."
echo "    Health : $HEALTH_URL"
echo "    MCP    : $MCP_URL"
echo ""
echo "    To remove everything:  az group delete --name $RESOURCE_GROUP --yes --no-wait"

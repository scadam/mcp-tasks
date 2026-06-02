#!/usr/bin/env bash
#
# Package and provision the Specialized Bikes declarative agent with the
# Microsoft 365 Agents Toolkit CLI (atk).
#
# It externalises the app version and the Application Gateway URL endpoint for
# the remote MCP server through a local `.env` file, writes them into the atk
# environment file (env/.env.<env>), keeps mcp-plugin.json in sync with
# tools.json, and then runs `atk provision`.
#
# Usage:
#   cp .env.example .env      # then edit APP_VERSION and REMOTE_MCP_URL
#   ./provision.sh            # provision the default (dev) environment
#   ./provision.sh --publish  # also publish to the Teams Admin Center
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DO_PUBLISH=0
for arg in "$@"; do
    case "$arg" in
        --publish) DO_PUBLISH=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# ── Load externalised configuration from .env ──────────────────────────────
if [[ ! -f .env ]]; then
    echo "ERROR: .env not found. Copy .env.example to .env and fill it in." >&2
    exit 1
fi
set -a
# shellcheck disable=SC1091
source ./.env
set +a

: "${APP_VERSION:?APP_VERSION must be set in .env}"
: "${REMOTE_MCP_URL:?REMOTE_MCP_URL must be set in .env}"
ENV_NAME="${TEAMSFX_ENV:-dev}"

if [[ "$REMOTE_MCP_URL" == *"your-app-gateway-endpoint"* ]]; then
    echo "ERROR: REMOTE_MCP_URL is still the placeholder; set it in .env." >&2
    exit 1
fi

echo "Environment : $ENV_NAME"
echo "App version : $APP_VERSION"
echo "MCP endpoint: $REMOTE_MCP_URL"

# ── Require the atk CLI ─────────────────────────────────────────────────────
if ! command -v atk >/dev/null 2>&1; then
    echo "ERROR: 'atk' (Microsoft 365 Agents Toolkit CLI) not found." >&2
    echo "Install it with: npm install -g @microsoft/m365agentstoolkit-cli" >&2
    exit 1
fi

# ── Keep mcp-plugin.json's tool description in sync with tools.json ──────────
echo "Syncing tools.json into mcp-plugin.json ..."
python3 - <<'PY'
import json

with open("appPackage/tools.json", encoding="utf-8") as fh:
    tools = json.load(fh)["tools"]

plugin_path = "appPackage/mcp-plugin.json"
with open(plugin_path, encoding="utf-8") as fh:
    plugin = json.load(fh)

plugin["runtimes"][0]["spec"]["mcp_tool_description"] = {"tools": tools}

with open(plugin_path, "w", encoding="utf-8") as fh:
    json.dump(plugin, fh, indent=4, ensure_ascii=False)
    fh.write("\n")
print(f"  wrote {len(tools)} tool description(s)")
PY

# ── Write the externalised values into the atk environment file ─────────────
ENV_DIR="env"
ENV_FILE="$ENV_DIR/.env.$ENV_NAME"
mkdir -p "$ENV_DIR"
touch "$ENV_FILE"

set_env_var() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$ENV_FILE"; then
        # Replace existing line (use a non-/ delimiter for URL values).
        sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

if ! grep -q "^TEAMSFX_ENV=" "$ENV_FILE"; then
    echo "TEAMSFX_ENV=$ENV_NAME" >> "$ENV_FILE"
fi
set_env_var "APP_VERSION" "$APP_VERSION"
set_env_var "REMOTE_MCP_URL" "$REMOTE_MCP_URL"
echo "Updated $ENV_FILE"

# ── Provision (and optionally publish) with atk ─────────────────────────────
echo "Running: atk provision --env $ENV_NAME"
atk provision --env "$ENV_NAME"

if [[ "$DO_PUBLISH" -eq 1 ]]; then
    echo "Running: atk publish --env $ENV_NAME"
    atk publish --env "$ENV_NAME"
fi

echo "Done."

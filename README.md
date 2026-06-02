# Specialized Bicycles MCP Server

A Python [FastMCP](https://github.com/jlowin/fastmcp) server, hosted as an
**Azure Function App**, that exposes the MCP **Streamable HTTP** transport
(SSE over HTTP streaming) with **anonymous** auth. It serves a demo catalog of
specialized bicycles through two tools, each backed by an interactive **React
single-page Skybridge widget**.

It also demonstrates **MCP Tasks** ([SEP-1686](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/1732)):
the long-running tool runs as a background task so it can complete well beyond
Azure Functions' HTTP request timeout.

## Endpoints

| Route     | Description                                              |
| --------- | -------------------------------------------------------- |
| `GET /health` | Liveness probe returning a small JSON status document. |
| `ANY /mcp`    | MCP Streamable HTTP endpoint (SSE over HTTP streaming). |

## Tools

| Tool                  | Latency | Task mode  | Widget (`ui://widgets/...`)        |
| --------------------- | ------- | ---------- | ---------------------------------- |
| `list_gravel_bikes`   | ~20s    | optional   | `gravel-explorer.html`             |
| `design_custom_bikes` | ~300s   | **required** | `custom-builds.html`             |

Both tools return MCP `content` (a text summary), `structuredContent` (the
bicycle payload the widget binds to), and `_meta`. The `_meta` carries
`openai/outputTemplate`, which points at the widget resource — this is what
binds the tool result to its UI.

### Why Tool 2 is an MCP Task

Azure Functions (and the App Service front end) enforce an HTTP idle timeout of
roughly **230 seconds**. A 300-second synchronous response would be cut off.
`design_custom_bikes` is therefore declared as a **required** MCP task: the call
returns a task id immediately, the work runs in a background worker, and the
client retrieves the result via `tasks/result` once it completes. The server
advertises task support through MCP capability negotiation (`capabilities.tasks`).

Tasks use FastMCP's **in-process `memory://` backend**, so no external broker
(Redis/Valkey) is required. The durable task state and the background worker
live inside the single Function App worker process. Because the store is
per-process, the app is deployed **Always-On** and **single-instance** (see
[`deploy/main.bicep`](deploy/main.bicep)).

## Widgets

The widgets are React 18 single-page HTML apps registered as MCP **resources**
at `ui://widgets/gravel-explorer.html` and `ui://widgets/custom-builds.html`
with mime type **`text/html+skybridge`**. They read the tool output from
`window.openai.toolOutput` (the `structuredContent`) and fall back to calling
the tool directly. They are theme-aware and render the bikes as an attractive
card layout.

## Project layout

```
function_app.py              Azure Functions ASGI entry point (anonymous auth)
host.json                    Functions host config (root route prefix)
requirements.txt             Runtime dependencies for the Functions build
pyproject.toml               Packaging + pytest config (src layout)
src/bikes_mcp/
  server.py                  FastMCP server: tools, widget resources, /health
  data.py                    Demo bicycle payloads
  widgets/*.html             React Skybridge widgets
deploy/
  main.bicep                 Infrastructure (storage, plan, Function App)
  deploy.sh                  One-click deploy + smoke test
tests/
  test_server_local.py       In-process tests (tools, widgets, task lifecycle)
  test_deployment.py         Smoke tests against a deployed URL (MCP_BASE_URL)
```

## Local development

```bash
python -m pip install -e ".[dev]"

# Run the Streamable HTTP server directly (uvicorn) with fast delays:
BIKES_TOOL_1_DELAY_SECONDS=0 BIKES_TOOL_2_DELAY_SECONDS=2 \
  python -m bikes_mcp.server      # serves http://localhost:8000/mcp + /health
```

Configurable environment variables:

| Variable                     | Default  | Purpose                              |
| ---------------------------- | -------- | ------------------------------------ |
| `BIKES_TOOL_1_DELAY_SECONDS` | `20`     | Tool 1 response delay.               |
| `BIKES_TOOL_2_DELAY_SECONDS` | `300`    | Tool 2 (task) response delay.        |
| `BIKES_TASK_TTL_MS`          | `900000` | Retention window for task results.   |

## Testing

```bash
# Fast in-process tests (no network); delays are forced low by tests/conftest.py
python -m pytest tests/test_server_local.py -q

# Smoke tests against a deployed (or locally running) instance:
MCP_BASE_URL=https://<app>.azurewebsites.net python -m pytest tests/test_deployment.py -q
# Use MCP_SMOKE_FAST=1 to only assert the task is accepted (skip the 300s wait).
```

## One-click deployment

Deploys to a **new** resource group, provisions infrastructure with Bicep,
publishes the code, waits for health, and runs the smoke tests:

```bash
az login
./deploy/deploy.sh                       # all defaults (generated names)
./deploy/deploy.sh -g my-rg -l westus2 -n mybikesapp
```

Requirements: Azure CLI (logged in), Azure Functions Core Tools (`func`),
`python3`. Tear everything down with:

```bash
az group delete --name <resource-group> --yes --no-wait
```

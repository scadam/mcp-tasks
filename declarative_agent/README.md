# Specialized Bikes — M365 Copilot Declarative Agent

A [Microsoft 365 Copilot declarative agent](https://aka.ms/teams-toolkit-declarative-agent)
that surfaces the two tools from the **Specialized Bicycles MCP server** inside
Copilot, each rendering its interactive widget:

| Tool                  | Conversation starter   | Behaviour                                            |
| --------------------- | ---------------------- | ---------------------------------------------------- |
| `list_gravel_bikes`   | *List Gravel Bikes*    | In-stock gravel/adventure bikes (~20s).              |
| `design_custom_bikes` | *Design Custom Bikes*  | Made-to-order custom builds, long-running MCP task.  |

The agent has **no capabilities** other than the single **action** linked to the
MCP plugin (`mcp-plugin.json`). It connects to the MCP server through a
`RemoteMCPServer` runtime pointed at your Application Gateway endpoint.

## Files

| File                            | Schema                          | Purpose                                                            |
| ------------------------------- | ------------------------------- | ----------------------------------------------------------------- |
| `appPackage/manifest.json`      | Teams manifest **v1.25**        | App package metadata; links the declarative agent and icons.      |
| `appPackage/declarative-agent.json` | declarative-agent **v1.6**  | Agent name, description, instructions, 2 conversation starters, 1 action. |
| `appPackage/mcp-plugin.json`    | copilot plugin **v2.4**         | `RemoteMCPServer` action; `spec.url` is the externalised endpoint. |
| `appPackage/tools.json`         | MCP tool description            | Canonical MCP tool descriptions; synced into `mcp-plugin.json`.   |
| `appPackage/instructions.txt`   | —                               | Agent instructions (referenced via `$[file('instructions.txt')]`). |
| `appPackage/color.png`          | 192×192 PNG                     | Full-color app icon.                                              |
| `appPackage/outline.png`        | 32×32 transparent PNG           | Outline app icon.                                                 |
| `m365agents.yml`                | atk project **v1.10**           | `atk provision` / `atk publish` stage definitions.                |
| `provision.sh`                  | —                               | Packages and provisions the agent with `atk`.                     |

## Externalised configuration

Two values are externalised through a local `.env` file (copied from
`.env.example`):

| `.env` key       | Substitutes               | Meaning                                               |
| ---------------- | ------------------------- | ----------------------------------------------------- |
| `APP_VERSION`    | `${{APP_VERSION}}`        | App/manifest version (and the agent display name).    |
| `REMOTE_MCP_URL` | `${{REMOTE_MCP_URL}}`     | Application Gateway URL endpoint for the remote MCP server. |

`provision.sh` writes these into the atk environment file
(`env/.env.<env>`); the toolkit then substitutes the matching `${{...}}`
placeholders when it builds the app package.

## Prerequisites

- A Microsoft 365 account with a Copilot license and custom-app upload enabled.
- [Microsoft 365 Agents Toolkit CLI](https://aka.ms/teamsfx-toolkit-cli) (`atk`):
  `npm install -g @microsoft/m365agentstoolkit-cli`
- Node.js 18, 20 or 22 and Python 3.
- The MCP server deployed and reachable at a public endpoint (see
  [`../deploy/deploy.sh`](../deploy/deploy.sh) and
  [`../deploy/deploy-gateway.sh`](../deploy/deploy-gateway.sh)).

## Package and provision

```bash
cd declarative_agent
cp .env.example .env          # set APP_VERSION and REMOTE_MCP_URL
atk auth login m365           # sign in once
./provision.sh                # build + provision the dev environment
./provision.sh --publish      # also publish to the Teams Admin Center
```

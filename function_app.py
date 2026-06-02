"""Azure Functions entry point for the Specialized Bicycles MCP server.

This wraps the FastMCP Streamable HTTP ASGI application in an
``AsgiFunctionApp`` with anonymous authentication and a root (empty) route
prefix, so the routes are exposed exactly as:

* ``GET  /health`` — health probe
* ``ANY  /mcp``    — MCP Streamable HTTP endpoint (SSE over HTTP streaming)

The Azure Functions ASGI middleware drives the ASGI lifespan, which is what
starts the in-process MCP task worker (FastMCP ``memory://`` backend). The
Function App must run on an Always-On, single-instance plan so the worker
stays alive long enough to complete the 300-second task.
"""

from __future__ import annotations

import sys
from pathlib import Path

import azure.functions as func

# The MCP server package lives under ``src/`` (src layout). Ensure it is
# importable when the Functions host loads this module from the app root.
_SRC = Path(__file__).resolve().parent / "src"
if _SRC.is_dir() and str(_SRC) not in sys.path:
    sys.path.insert(0, str(_SRC))

from bikes_mcp.server import create_app  # noqa: E402

# The MCP Streamable HTTP app, mounted at /mcp, with a /health custom route.
asgi_app = create_app(path="/mcp")

# http_auth_level=ANONYMOUS => no function keys required (anonymous auth).
app = func.AsgiFunctionApp(app=asgi_app, http_auth_level=func.AuthLevel.ANONYMOUS)

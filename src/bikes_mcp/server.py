"""Specialized Bicycles MCP server.

A FastMCP server that exposes two tools, each backed by a React single-page
Skybridge widget:

* ``list_gravel_bikes``  — responds after ~20s, renders the gravel widget.
* ``design_custom_bikes`` — responds after ~300s, runs as an **MCP Task**
  (SEP-1686) so it can complete beyond Azure Functions' ~230s HTTP limit.

Both tools return ``content`` + ``structuredContent`` + ``_meta``. The widgets
are registered both as MCP server resources (``ui://widgets/...``) and bound to
their tool via the ``openai/outputTemplate`` metadata key, which references the
widget resource. Widgets bind to the tool ``structuredContent``.

Transport is Streamable HTTP (SSE over HTTP streaming). Authentication is
anonymous. A ``/health`` route is exposed alongside the ``/mcp`` endpoint.

MCP Tasks use FastMCP's in-process ``memory://`` task backend, so no external
broker (Redis/Valkey) is required — the durable task state and the background
worker live inside the single Function App worker process.
"""

from __future__ import annotations

import asyncio
import os
from pathlib import Path
from typing import Any

import mcp.types as types
from fastmcp import FastMCP
from fastmcp.resources import TextResource
from fastmcp.server.tasks.config import TaskConfig
from fastmcp.tools.tool import ToolResult
from starlette.requests import Request
from starlette.responses import JSONResponse

from . import data

# Skybridge widget mime type (per the OpenAI Apps SDK / ess-mcp convention).
WIDGET_MIME_TYPE = "text/html+skybridge"

# Widget resource URIs (the task specifies the ``ui://widgets/...`` namespace).
GRAVEL_WIDGET_URI = "ui://widgets/gravel-explorer.html"
CUSTOM_WIDGET_URI = "ui://widgets/custom-builds.html"

_WIDGET_DIR = Path(__file__).resolve().parent / "widgets"


def _int_env(name: str, default: int) -> int:
    """Read a non-negative integer from the environment, falling back to default."""
    raw = os.getenv(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value >= 0 else default


# Response delays (seconds). Defaults match the spec (20s / 300s) but can be
# overridden via environment variables — primarily so tests can run quickly.
TOOL_1_DELAY_SECONDS = _int_env("BIKES_TOOL_1_DELAY_SECONDS", 20)
TOOL_2_DELAY_SECONDS = _int_env("BIKES_TOOL_2_DELAY_SECONDS", 300)

# Default task TTL (ms) — how long completed task results are retained for
# polling/retrieval. 300s build + generous retrieval window.
TASK_TTL_MS = _int_env("BIKES_TASK_TTL_MS", 900_000)


def _read_widget(filename: str) -> str:
    return (_WIDGET_DIR / filename).read_text(encoding="utf-8")


def _widget_meta() -> dict[str, Any]:
    """Skybridge widget resource metadata (CSP placeholder, per ess-mcp)."""
    return {
        "openai/widgetCSP": {
            "connect_domains": [],
            "resource_domains": ["https://unpkg.com"],
        }
    }


def _tool_meta(output_template: str, invoking: str, invoked: str) -> dict[str, Any]:
    """Tool ``_meta`` binding the result to a widget via outputTemplate."""
    return {
        "openai/outputTemplate": output_template,
        "openai/toolInvocation/invoking": invoking,
        "openai/toolInvocation/invoked": invoked,
        "openai/widgetAccessible": True,
    }


GRAVEL_TOOL_META = _tool_meta(
    GRAVEL_WIDGET_URI,
    "Pulling specialized gravel bikes…",
    "Gravel bikes ready.",
)
CUSTOM_TOOL_META = _tool_meta(
    CUSTOM_WIDGET_URI,
    "Spinning up the custom build workshop…",
    "Custom builds ready.",
)


def build_server() -> FastMCP:
    """Create and configure the Specialized Bicycles FastMCP server."""
    mcp = FastMCP(
        name="specialized-bikes",
        instructions=(
            "Specialized bicycles catalog. Use `list_gravel_bikes` for in-stock "
            "gravel/adventure bikes, and `design_custom_bikes` for made-to-order "
            "custom builds (a long-running MCP task). Both render interactive widgets."
        ),
        # Enable MCP Tasks (SEP-1686) support for the whole server.
        tasks=True,
    )

    # ── Widget resources (ui://widgets/...) ────────────────────────────────
    mcp.add_resource(
        TextResource(
            uri=GRAVEL_WIDGET_URI,
            name="gravel-explorer",
            description="Interactive React widget rendering specialized gravel bikes.",
            mime_type=WIDGET_MIME_TYPE,
            text=_read_widget("gravel-explorer.html"),
            meta=_widget_meta(),
        )
    )
    mcp.add_resource(
        TextResource(
            uri=CUSTOM_WIDGET_URI,
            name="custom-builds",
            description="Interactive React widget rendering made-to-order custom bike builds.",
            mime_type=WIDGET_MIME_TYPE,
            text=_read_widget("custom-builds.html"),
            meta=_widget_meta(),
        )
    )

    # ── Tool 1: gravel bikes (≈20s, sync; tasks optional) ──────────────────
    @mcp.tool(
        name="list_gravel_bikes",
        description=(
            "List in-stock specialized gravel & adventure bikes. Responds after "
            "about 20 seconds and renders the gravel bikes widget."
        ),
        meta=GRAVEL_TOOL_META,
        annotations={"readOnlyHint": True, "title": "List gravel bikes"},
        task=TaskConfig(mode="optional"),
    )
    async def list_gravel_bikes() -> ToolResult:
        await asyncio.sleep(TOOL_1_DELAY_SECONDS)
        payload = data.gravel_payload()
        summary = (
            f"Found {payload['count']} specialized gravel bikes "
            f"(from {payload['priceRange']['min']:,} to {payload['priceRange']['max']:,} "
            f"{payload['currency']})."
        )
        return ToolResult(
            content=[types.TextContent(type="text", text=summary)],
            structured_content=payload,
            meta=GRAVEL_TOOL_META,
        )

    # ── Tool 2: custom builds (≈300s, MCP Task required) ───────────────────
    @mcp.tool(
        name="design_custom_bikes",
        description=(
            "Generate a set of made-to-order custom bicycle builds. This is a "
            "long-running operation (about 300 seconds) and runs as an MCP task: "
            "it returns a task id immediately and the result is retrieved via "
            "tasks/result once complete. Renders the custom builds widget."
        ),
        meta=CUSTOM_TOOL_META,
        annotations={"readOnlyHint": True, "title": "Design custom bikes"},
        # `required` => the tool advertises taskHint "always" and must be invoked
        # as a task. This is what lets it exceed the Azure Functions HTTP timeout.
        task=TaskConfig(mode="required"),
    )
    async def design_custom_bikes() -> ToolResult:
        await asyncio.sleep(TOOL_2_DELAY_SECONDS)
        payload = data.custom_payload()
        summary = (
            f"Designed {payload['count']} custom bicycle builds "
            f"(from {payload['priceRange']['min']:,} to {payload['priceRange']['max']:,} "
            f"{payload['currency']}; {payload['leadTimeWeeks']['min']}–"
            f"{payload['leadTimeWeeks']['max']} week lead time)."
        )
        return ToolResult(
            content=[types.TextContent(type="text", text=summary)],
            structured_content=payload,
            meta=CUSTOM_TOOL_META,
        )

    # ── Health endpoint ────────────────────────────────────────────────────
    @mcp.custom_route("/health", methods=["GET"])
    async def health(_request: Request) -> JSONResponse:
        return JSONResponse(
            {
                "status": "healthy",
                "server": "specialized-bikes",
                "transport": "streamable-http",
                "tools": ["list_gravel_bikes", "design_custom_bikes"],
                "tasks": True,
            }
        )

    return mcp


# Module-level singleton used by both the ASGI/Functions host and local runners.
mcp_server = build_server()


def create_app(path: str = "/mcp"):
    """Return the Streamable HTTP ASGI application for the MCP server.

    Args:
        path: The route the MCP endpoint is mounted at (default ``/mcp``).
    """
    return mcp_server.http_app(path=path, transport="http")


if __name__ == "__main__":
    # Local dev: run the streamable-HTTP server with uvicorn.
    import uvicorn

    port = _int_env("PORT", 8000)
    uvicorn.run(create_app(), host="0.0.0.0", port=port)

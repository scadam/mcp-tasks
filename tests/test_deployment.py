"""Deployment smoke tests.

These run against a *deployed* (or locally running) instance of the bikes MCP
server. They are skipped automatically unless ``MCP_BASE_URL`` is set, e.g.::

    MCP_BASE_URL=https://my-bikes-app.azurewebsites.net pytest tests/test_deployment.py

``deploy/deploy.sh`` sets ``MCP_BASE_URL`` and invokes this module as the
post-deployment verification step.

The custom-builds task is long-running in production (~300s). To keep CI/smoke
runs bounded, the task lifecycle assertion only waits up to
``MCP_TASK_TIMEOUT_SECONDS`` (default 330) and is skipped entirely when
``MCP_SMOKE_FAST=1`` (it then only verifies the task was *accepted*).
"""

from __future__ import annotations

import os

import httpx
import pytest
from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport

BASE_URL = os.getenv("MCP_BASE_URL")
TASK_TIMEOUT = int(os.getenv("MCP_TASK_TIMEOUT_SECONDS", "330"))
SMOKE_FAST = os.getenv("MCP_SMOKE_FAST", "") not in ("", "0", "false", "False")

pytestmark = pytest.mark.skipif(
    not BASE_URL, reason="set MCP_BASE_URL to run deployment smoke tests"
)


def _base() -> str:
    return BASE_URL.rstrip("/")


def _mcp_url() -> str:
    return f"{_base()}/mcp"


async def test_health_endpoint():
    async with httpx.AsyncClient(timeout=30) as http:
        resp = await http.get(f"{_base()}/health")
        resp.raise_for_status()
        body = resp.json()
        assert body["status"] == "healthy"
        assert body["tasks"] is True
        assert "design_custom_bikes" in body["tools"]


async def test_initialize_and_tools_over_http():
    async with Client(StreamableHttpTransport(_mcp_url())) as client:
        caps = client.initialize_result.capabilities
        assert caps.tasks is not None  # MCP Tasks advertised by the deployment

        tools = {t.name: t for t in await client.list_tools()}
        assert {"list_gravel_bikes", "design_custom_bikes"} <= set(tools)
        assert tools["design_custom_bikes"].meta["openai/outputTemplate"].startswith(
            "ui://widgets/"
        )


async def test_widgets_served_over_http():
    async with Client(StreamableHttpTransport(_mcp_url())) as client:
        resources = {str(r.uri): r for r in await client.list_resources()}
        assert any(u.startswith("ui://widgets/") for u in resources)
        for uri, res in resources.items():
            if uri.startswith("ui://widgets/"):
                assert res.mimeType == "text/html+skybridge"


async def test_custom_builds_task_accepted_over_http():
    async with Client(StreamableHttpTransport(_mcp_url())) as client:
        task = await client.call_tool(
            "design_custom_bikes", {}, task=True, ttl=TASK_TIMEOUT * 1000
        )
        # The server must return a task id immediately rather than blocking for
        # the full build (this is what keeps it under the Azure 230s HTTP limit).
        assert task.returned_immediately is False
        assert task.task_id

        if SMOKE_FAST:
            pytest.skip("MCP_SMOKE_FAST set: skipping full 300s task wait")

        status = await task.wait(timeout=TASK_TIMEOUT)
        assert status.status == "completed"
        result = await task.result()
        sc = result.structured_content
        assert sc["count"] == len(sc["bikes"]) >= 1
        assert result.meta["openai/outputTemplate"].startswith("ui://widgets/")

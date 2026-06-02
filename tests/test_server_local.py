"""In-process tests for the Specialized Bicycles MCP server.

These tests exercise the server through an in-memory FastMCP ``Client`` (no
network), validating tools, widget resources, ``content``/``structuredContent``/
``_meta`` shape, the widget<->tool binding, and the MCP Tasks lifecycle.

Delays are forced to ~0/1s via environment variables (set in ``conftest.py``)
so the suite runs quickly.
"""

from __future__ import annotations

import pytest
from fastmcp import Client

from bikes_mcp.server import (
    CUSTOM_WIDGET_URI,
    GRAVEL_WIDGET_URI,
    WIDGET_MIME_TYPE,
    build_server,
)


@pytest.fixture
def server():
    return build_server()


async def test_tasks_capability_advertised(server):
    async with Client(server) as client:
        caps = client.initialize_result.capabilities
        assert caps.tasks is not None
        # Server advertises task-augmented tools/call support.
        assert caps.tasks.requests is not None
        assert caps.tasks.requests.tools is not None


async def test_lists_two_tools_bound_to_widgets(server):
    async with Client(server) as client:
        tools = {t.name: t for t in await client.list_tools()}
        assert set(tools) == {"list_gravel_bikes", "design_custom_bikes"}
        assert tools["list_gravel_bikes"].meta["openai/outputTemplate"] == GRAVEL_WIDGET_URI
        assert tools["design_custom_bikes"].meta["openai/outputTemplate"] == CUSTOM_WIDGET_URI


async def test_widget_resources_are_skybridge(server):
    async with Client(server) as client:
        resources = {str(r.uri): r for r in await client.list_resources()}
        assert GRAVEL_WIDGET_URI in resources
        assert CUSTOM_WIDGET_URI in resources
        for uri in (GRAVEL_WIDGET_URI, CUSTOM_WIDGET_URI):
            assert resources[uri].mimeType == WIDGET_MIME_TYPE
            contents = await client.read_resource(uri)
            html = contents[0].text
            assert "<!DOCTYPE html>" in html
            assert "window.openai" in html  # Skybridge wiring
            assert "react" in html.lower()  # React single-page app


async def test_gravel_tool_returns_content_structured_and_meta(server):
    async with Client(server) as client:
        result = await client.call_tool_mcp("list_gravel_bikes", {})
        # content
        assert result.content and result.content[0].text
        # structuredContent (widgets bind to this)
        sc = result.structuredContent
        assert sc["count"] == len(sc["bikes"]) == 4
        assert all("priceUsd" in b for b in sc["bikes"])
        # _meta references the widget as the output template
        assert result.meta["openai/outputTemplate"] == GRAVEL_WIDGET_URI


async def test_custom_tool_requires_task_augmentation(server):
    async with Client(server) as client:
        # design_custom_bikes is task=required: a plain sync call must be rejected.
        with pytest.raises(Exception):
            await client.call_tool("design_custom_bikes", {})


async def test_custom_tool_task_lifecycle(server):
    async with Client(server) as client:
        task = await client.call_tool("design_custom_bikes", {}, task=True, ttl=60000)
        # CreateTaskResult returned immediately, before completion.
        assert task.returned_immediately is False
        assert task.task_id

        status = await task.wait(timeout=30)
        assert status.status == "completed"

        result = await task.result()
        assert result.content and result.content[0].text
        sc = result.structured_content
        assert sc["count"] == len(sc["bikes"]) == 3
        assert result.meta["openai/outputTemplate"] == CUSTOM_WIDGET_URI


async def test_task_listing_and_status(server):
    async with Client(server) as client:
        task = await client.call_tool("design_custom_bikes", {}, task=True, ttl=60000)
        status = await client.get_task_status(task.task_id)
        assert status.taskId == task.task_id
        assert status.status in ("working", "completed")
        await task.wait(timeout=30)

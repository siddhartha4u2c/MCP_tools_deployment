"""
A tiny MCP client. It connects to an MCP server over HTTP, lists what the
server offers, and calls each kind of thing once.

Usage:
  python client.py                                   # talks to http://localhost:8000/mcp
  python client.py http://<aws-host>:8000/mcp        # talks to your AWS deployment
Set MCP_API_KEY in your environment if the server requires it.
"""

import asyncio
import os
import sys

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


async def main(url: str) -> None:
    headers = {}
    if api_key := os.getenv("MCP_API_KEY"):
        headers["Authorization"] = f"Bearer {api_key}"

    # 1. Open the transport (HTTP), 2. start an MCP session on top of it.
    async with streamablehttp_client(url, headers=headers) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()  # handshake: exchange capabilities

            tools = await session.list_tools()
            print("Tools:", [t.name for t in tools.tools])

            result = await session.call_tool("add", {"a": 2, "b": 3})
            print("add(2, 3) ->", result.content[0].text)

            result = await session.call_tool("word_count", {"text": "hello model context protocol"})
            print("word_count ->", result.content[0].text)

            result = await session.call_tool("utc_now", {})
            print("utc_now ->", result.content[0].text)

            resource = await session.read_resource("notes://welcome")
            print("resource ->", resource.contents[0].text)

            prompt = await session.get_prompt("summarize", {"text": "MCP connects AI apps to tools."})
            print("prompt ->", prompt.messages[0].content.text)


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8000/mcp"))

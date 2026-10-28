"""
A tiny MCP server that shows the three MCP building blocks:

  - Tools     -> functions the AI can CALL        (add, word_count, utc_now)
  - Resources -> read-only data the AI can READ   (notes://welcome)
  - Prompts   -> reusable prompt templates        (summarize)

Run it two ways:
  python server.py --stdio   # local: a desktop client (Claude Desktop, etc.) starts it as a subprocess
  python server.py           # remote: an HTTP server on port 8000 at /mcp (this is what runs on AWS)
"""

import os
import sys
from datetime import datetime, timezone

import uvicorn
from mcp.server.fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse

# stateless_http=True: each request is independent, so you can run many copies
# behind a load balancer with no shared session state.
mcp = FastMCP("demo-server", stateless_http=True, json_response=True)


# ---------- Tools ----------
@mcp.tool()
def add(a: float, b: float) -> float:
    """Add two numbers."""
    return a + b


@mcp.tool()
def word_count(text: str) -> dict:
    """Count the words and characters in a piece of text."""
    return {"words": len(text.split()), "characters": len(text)}


@mcp.tool()
def utc_now() -> str:
    """Return the current UTC time in ISO 8601 format."""
    return datetime.now(timezone.utc).isoformat()


# ---------- Resource ----------
@mcp.resource("notes://welcome")
def welcome_note() -> str:
    """A static note the client can read."""
    return "Welcome to the demo MCP server. Try the add, word_count and utc_now tools."


# ---------- Prompt ----------
@mcp.prompt()
def summarize(text: str) -> str:
    """A prompt template that asks the model to summarize text."""
    return f"Summarize the following text in three bullet points:\n\n{text}"


# ---------- Health check (used by AWS to know the container is alive) ----------
@mcp.custom_route("/health", methods=["GET"])
async def health(_: Request) -> JSONResponse:
    return JSONResponse({"status": "ok"})


# ---------- Simple API-key protection for the public HTTP endpoint ----------
class ApiKeyMiddleware:
    """Rejects requests to /mcp unless they send `Authorization: Bearer <MCP_API_KEY>`.

    If MCP_API_KEY is not set (local development), every request is allowed.
    """

    def __init__(self, app, api_key: str | None):
        self.app = app
        self.api_key = api_key

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and self.api_key and scope["path"] != "/health":
            headers = dict(scope["headers"])
            if headers.get(b"authorization", b"").decode() != f"Bearer {self.api_key}":
                await JSONResponse({"error": "unauthorized"}, status_code=401)(scope, receive, send)
                return
        await self.app(scope, receive, send)


if __name__ == "__main__":
    if "--stdio" in sys.argv:
        mcp.run(transport="stdio")
    else:
        app = ApiKeyMiddleware(mcp.streamable_http_app(), os.getenv("MCP_API_KEY"))
        uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", "8000")))

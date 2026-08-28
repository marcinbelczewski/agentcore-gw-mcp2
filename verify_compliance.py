"""Verify lambda_function.py against MCP 2026-07-28 using the official SDK.

The Lambda stays dependency-free; this script is the compliance oracle. It
wraps `lambda_function.lambda_handler` in a local stdlib HTTP shim that mimics
the Lambda Function URL event shape, then drives it two ways:

1. Positive path: the official `mcp` Python SDK client (which implements the
   2026-07-28 revision: `server/discover`, per-request `_meta`, intent
   headers, and pydantic response validation) discovers the server, lists
   tools, and calls the echo tool.
2. Strictness path: plain stdlib requests prove the server rejects the legacy
   `initialize` handshake, missing `_meta`, and mismatched intent headers.

Run via: make verify-compliance  (uv pulls the SDK ephemerally)
"""

from __future__ import annotations

import asyncio
import json
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import lambda_function

FAILURES: list[str] = []


def check(name: str, condition: bool, detail: object = "") -> None:
    status = "ok" if condition else "FAIL"
    print(f"{status:4} {name}" + (f" -> {detail}" if detail != "" else ""))
    if not condition:
        FAILURES.append(name)


class FunctionUrlShim(BaseHTTPRequestHandler):
    """Translate plain HTTP into Lambda Function URL events and back."""

    protocol_version = "HTTP/1.1"

    def _serve(self, method: str) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        event = {
            "rawPath": self.path,
            "headers": {name.lower(): value for name, value in self.headers.items()},
            "requestContext": {"http": {"method": method}},
            "body": self.rfile.read(length).decode() if length else "",
            "isBase64Encoded": False,
        }
        response = lambda_function.lambda_handler(event, None)
        body = (response.get("body") or "").encode()
        self.send_response(response["statusCode"])
        for name, value in (response.get("headers") or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        self._serve("GET")

    def do_POST(self) -> None:
        self._serve("POST")

    def log_message(self, format: str, *args: object) -> None:
        return


def post(url: str, body: dict[str, object], headers: dict[str, str]) -> tuple[int, dict[str, object]]:
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", **headers},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())


async def verify_with_official_sdk(url: str) -> None:
    from mcp import types
    from mcp.client.session import ClientSession
    from mcp.client.streamable_http import streamable_http_client

    async with streamable_http_client(url) as (read_stream, write_stream):
        async with ClientSession(read_stream, write_stream) as session:
            discovered = await session.discover()
            check("SDK server/discover returns a valid DiscoverResult", isinstance(discovered, types.DiscoverResult))
            check(
                "negotiated protocol version is 2026-07-28",
                session.protocol_version == "2026-07-28",
                session.protocol_version,
            )
            check(
                "discover advertises only 2026-07-28",
                discovered.supported_versions == ["2026-07-28"],
                discovered.supported_versions,
            )

            tools = await session.list_tools()
            check(
                "SDK tools/list returns the echo tool",
                [tool.name for tool in tools.tools] == ["echo"],
                [tool.name for tool in tools.tools],
            )

            result = await session.call_tool("echo", {"message": "compliance"})
            check("SDK tools/call succeeds", isinstance(result, types.CallToolResult) and not result.is_error)
            check(
                "tools/call echoes structured content",
                getattr(result, "structured_content", None) == {"message": "compliance"},
                getattr(result, "structured_content", None),
            )


def verify_strictness(url: str) -> None:
    status, body = post(
        url,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "legacy", "version": "1.0"}},
        },
        {"MCP-Protocol-Version": "2025-11-25"},
    )
    check(
        "legacy initialize @2025-11-25 rejected with 400/-32022",
        status == 400 and body.get("error", {}).get("code") == -32022,
        (status, body.get("error", {}).get("code")),
    )

    status, body = post(
        url,
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        {"MCP-Protocol-Version": "2026-07-28"},
    )
    check(
        "2026 request without _meta rejected with 400/-32602",
        status == 400 and body.get("error", {}).get("code") == -32602,
        (status, body.get("error", {}).get("code")),
    )

    status, body = post(
        url,
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/list",
            "params": {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}},
        },
        {"MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call"},
    )
    check(
        "Mcp-Method header/body mismatch rejected with 400/-32020",
        status == 400 and body.get("error", {}).get("code") == -32020,
        (status, body.get("error", {}).get("code")),
    )

    status, body = post(
        url,
        {"jsonrpc": "2.0", "id": 4, "method": "tools/list", "params": {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}}},
        {},
    )
    check(
        "request without MCP-Protocol-Version header treated as 2025-03-26 and rejected",
        status == 400
        and body.get("error", {}).get("code") == -32022
        and body.get("error", {}).get("data", {}).get("requested") == "2025-03-26",
        (status, body.get("error", {})),
    )


def main() -> int:
    server = ThreadingHTTPServer(("127.0.0.1", 0), FunctionUrlShim)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}/"
    try:
        asyncio.run(verify_with_official_sdk(url))
        verify_strictness(url)
    finally:
        server.shutdown()

    if FAILURES:
        print(f"\n{len(FAILURES)} compliance check(s) failed.")
        return 1
    print("\nAll compliance checks passed against the official MCP SDK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

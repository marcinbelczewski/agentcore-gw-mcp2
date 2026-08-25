"""Minimal, dependency-free MCP 2026-07-28-only server.

The server deliberately rejects every older protocol version with HTTP 400
and JSON-RPC -32022. This is the behavior that AgentCore Gateway DEFAULT
listing mode cannot currently index: target creation sends
`initialize @2025-11-25` instead of `server/discover @2026-07-28`.
"""

from __future__ import annotations

import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

PROTOCOL_VERSION = "2026-07-28"
SERVER_INFO = {"name": "agentcore-gw-mcp2-repro", "version": "1.0.0"}
TOOLS = [
    {
        "name": "echo",
        "description": "Return the supplied message.",
        "inputSchema": {
            "type": "object",
            "properties": {"message": {"type": "string"}},
            "required": ["message"],
        },
    }
]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "agentcore-gw-mcp2-repro"
    sys_version = ""

    def do_GET(self) -> None:
        if urlsplit(self.path).path == "/ping":
            self.send_json(200, {"status": "Healthy"})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if urlsplit(self.path).path != "/mcp":
            self.send_json(404, {"error": "not found"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            request = json.loads(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError):
            self.rpc_error(400, None, -32700, "Parse error")
            return

        request_id = request.get("id")
        method = request.get("method")
        params = request.get("params") or {}
        version = self.headers.get("MCP-Protocol-Version") or "2025-03-26"

        # This log line is the primary reproduction evidence in CloudWatch.
        print(
            json.dumps(
                {
                    "timestamp": round(time.time(), 3),
                    "method": method,
                    "protocol_version_header": self.headers.get(
                        "MCP-Protocol-Version"
                    ),
                    "mcp_method_header": self.headers.get("Mcp-Method"),
                    "has_meta": "_meta" in params,
                }
            ),
            flush=True,
        )

        if version != PROTOCOL_VERSION:
            self.rpc_error(
                400,
                request_id,
                -32022,
                "Unsupported protocol version",
                {"supported": [PROTOCOL_VERSION], "requested": version},
            )
            return

        if request_id is None:
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        declared_method = self.headers.get("Mcp-Method")
        if declared_method is not None and declared_method != method:
            self.rpc_error(400, request_id, -32020, "Mcp-Method mismatch")
            return

        if method == "tools/call":
            declared_name = self.headers.get("Mcp-Name")
            if declared_name is not None and declared_name != params.get("name"):
                self.rpc_error(400, request_id, -32020, "Mcp-Name mismatch")
                return

        meta = params.get("_meta") or {}
        meta_version = meta.get("io.modelcontextprotocol/protocolVersion")
        if meta_version is None:
            self.rpc_error(
                400,
                request_id,
                -32602,
                "Missing required '_meta' field: "
                "io.modelcontextprotocol/protocolVersion",
            )
            return
        if meta_version != version:
            self.rpc_error(
                400,
                request_id,
                -32020,
                "_meta protocolVersion does not match "
                "MCP-Protocol-Version header",
            )
            return

        if method == "server/discover":
            result = {
                "supportedVersions": [PROTOCOL_VERSION],
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": SERVER_INFO,
                "ttlMs": 300_000,
                "cacheScope": "public",
            }
        elif method == "tools/list":
            result = {
                "tools": TOOLS,
                "ttlMs": 300_000,
                "cacheScope": "public",
            }
        elif method == "tools/call":
            if params.get("name") != "echo":
                self.rpc_error(200, request_id, -32602, "Unknown tool")
                return
            message = (params.get("arguments") or {}).get("message", "")
            result = {
                "resultType": "complete",
                "content": [{"type": "text", "text": message}],
                "structuredContent": {"message": message},
                "isError": False,
            }
        else:
            self.rpc_error(404, request_id, -32601, "Method not found")
            return

        self.send_json(
            200,
            {"jsonrpc": "2.0", "id": request_id, "result": result},
        )

    def rpc_error(
        self,
        status: int,
        request_id: object,
        code: int,
        message: str,
        data: dict[str, object] | None = None,
    ) -> None:
        error: dict[str, object] = {"code": code, "message": message}
        if data is not None:
            error["data"] = data
        self.send_json(
            status,
            {"jsonrpc": "2.0", "id": request_id, "error": error},
        )

    def send_json(self, status: int, body: dict[str, object]) -> None:
        encoded = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, format: str, *args: object) -> None:
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", 8000), Handler)
    server.daemon_threads = True
    server.serve_forever()

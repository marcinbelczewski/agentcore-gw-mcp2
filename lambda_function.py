"""Minimal, dependency-free MCP 2026-07-28-only server for Lambda Function URLs.

Same strict protocol policy as main.py (the AgentCore Runtime variant), ported
to the Lambda Function URL event shape: every request older than 2026-07-28 is
rejected with HTTP 400 and JSON-RPC -32022, and 2026-07-28 requests must carry
the per-request `_meta` protocol version. The structured log line printed for
every request is the reproduction evidence in CloudWatch.
"""

from __future__ import annotations

import base64
import json
import time

PROTOCOL_VERSION = "2026-07-28"
SERVER_INFO = {"name": "agentcore-gw-mcp2-repro-lambda", "version": "1.0.0"}
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


def _response(status: int, body: dict[str, object] | None = None) -> dict[str, object]:
    if body is None:
        return {"statusCode": status, "body": ""}
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, separators=(",", ":")),
    }


def _rpc_error(
    status: int,
    request_id: object,
    code: int,
    message: str,
    data: dict[str, object] | None = None,
) -> dict[str, object]:
    error: dict[str, object] = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    return _response(status, {"jsonrpc": "2.0", "id": request_id, "error": error})


def lambda_handler(event: dict[str, object], _context: object) -> dict[str, object]:
    raw_path = event.get("rawPath") or "/"
    http = (event.get("requestContext") or {}).get("http") or {}
    if http.get("method") == "GET":
        if raw_path == "/ping":
            return _response(200, {"status": "Healthy"})
        return _response(404, {"error": "not found"})

    raw_body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw_body = base64.b64decode(raw_body)
    try:
        request = json.loads(raw_body)
    except (ValueError, json.JSONDecodeError):
        return _rpc_error(400, None, -32700, "Parse error")

    request_id = request.get("id")
    method = request.get("method")
    params = request.get("params") or {}

    # Function URL events lowercase all header names.
    headers = {name.lower(): value for name, value in (event.get("headers") or {}).items()}
    version = headers.get("mcp-protocol-version") or "2025-03-26"

    # This log line is the primary reproduction evidence in CloudWatch.
    print(
        json.dumps(
            {
                "timestamp": round(time.time(), 3),
                "method": method,
                "protocol_version_header": headers.get("mcp-protocol-version"),
                "mcp_method_header": headers.get("mcp-method"),
                "has_meta": "_meta" in params,
            }
        ),
        flush=True,
    )

    if version != PROTOCOL_VERSION:
        return _rpc_error(
            400,
            request_id,
            -32022,
            "Unsupported protocol version",
            {"supported": [PROTOCOL_VERSION], "requested": version},
        )

    if request_id is None:
        return _response(202)

    declared_method = headers.get("mcp-method")
    if declared_method is not None and declared_method != method:
        return _rpc_error(400, request_id, -32020, "Mcp-Method mismatch")

    if method == "tools/call":
        declared_name = headers.get("mcp-name")
        if declared_name is not None and declared_name != params.get("name"):
            return _rpc_error(400, request_id, -32020, "Mcp-Name mismatch")

    meta = params.get("_meta") or {}
    meta_version = meta.get("io.modelcontextprotocol/protocolVersion")
    if meta_version is None:
        return _rpc_error(
            400,
            request_id,
            -32602,
            "Missing required '_meta' field: io.modelcontextprotocol/protocolVersion",
        )
    if meta_version != version:
        return _rpc_error(
            400,
            request_id,
            -32020,
            "_meta protocolVersion does not match MCP-Protocol-Version header",
        )

    if method == "server/discover":
        result: dict[str, object] = {
            "supportedVersions": [PROTOCOL_VERSION],
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": SERVER_INFO,
            "ttlMs": 300_000,
            "cacheScope": "public",
        }
    elif method == "tools/list":
        result = {
            "tools": TOOLS,
            "resultType": "complete",
            "ttlMs": 300_000,
            "cacheScope": "public",
        }
    elif method == "tools/call":
        if params.get("name") != "echo":
            return _rpc_error(200, request_id, -32602, "Unknown tool")
        message = (params.get("arguments") or {}).get("message", "")
        result = {
            "resultType": "complete",
            "content": [{"type": "text", "text": message}],
            "structuredContent": {"message": message},
            "isError": False,
        }
    else:
        return _rpc_error(404, request_id, -32601, "Method not found")

    return _response(200, {"jsonrpc": "2.0", "id": request_id, "result": result})

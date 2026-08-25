# AgentCore Gateway DEFAULT listing cannot index an MCP 2026-07-28-only target

Minimal reproduction for an Amazon Bedrock AgentCore Gateway compatibility
issue.

## Problem

The deployment contains exactly:

- one IAM-protected AgentCore Runtime hosting a dependency-free MCP server;
- one IAM-protected AgentCore Gateway;
- one IAM-authenticated MCP server target using `listing_mode = "DEFAULT"`.

The Gateway advertises only the latest MCP version and has no session
configuration:

```hcl
protocol_configuration {
  mcp {
    supported_versions = ["2026-07-28"]
  }
}
```

The runtime application also accepts and advertises only `2026-07-28`.
Older versions are rejected with HTTP 400 and JSON-RPC `-32022`.

### Expected

Creating the DEFAULT-mode target should discover the server through MCP
`2026-07-28`, using `server/discover` and stateless list operations.

### Actual

`CreateGatewayTarget` performs a legacy session handshake:

```text
initialize                  MCP-Protocol-Version: 2025-11-25
notifications/initialized   MCP-Protocol-Version: 2025-11-25
tools/list                  MCP-Protocol-Version: 2025-11-25
```

The strict target rejects the first request. Target creation fails with a
message equivalent to:

```text
MCP server '<runtime URL>' returned HTTP 400 to the initialize handshake.
```

The runtime's CloudWatch log proves the request sent by Gateway:

```json
{
  "method": "initialize",
  "protocol_version_header": "2025-11-25",
  "mcp_method_header": null,
  "has_meta": false
}
```

This has been reproduced in `eu-west-1` and `us-east-1`. A Gateway created
from the start with only `2026-07-28` behaves the same way. The issue is
specific to DEFAULT capability indexing. DYNAMIC targets skip create-time
indexing and can onboard a strict `2026-07-28` server.

## Prerequisites

- current AWS credentials for the account under test;
- AWS CLI with `bedrock-agentcore` and `bedrock-agentcore-control` support;
- Terraform; and
- `jq` (only for pretty-printing the optional direct-runtime check).

No Python dependencies or application build step are required.

## Reproduce

```bash
make apply
```

The command is **expected to exit non-zero** while creating
`aws_bedrockagentcore_gateway_target.runtime`. The runtime and Gateway are
created successfully before the target fails. A 30-second wait is included
to rule out IAM propagation as the cause.

Optionally verify that the runtime itself handles `2026-07-28` directly:

```bash
make verify-runtime
```

Inspect the request received from Gateway:

```bash
make logs
```

Relevant configuration is intentionally explicit:

```hcl
# Gateway client-facing protocol
supported_versions = ["2026-07-28"]

# Target capability mode
listing_mode = "DEFAULT"

# Target authentication
credential_provider_configuration {
  gateway_iam_role {
    service = "bedrock-agentcore"
  }
}
```

AgentCore Runtime has no control-plane `supportedVersions` field. The
runtime's version policy is therefore enforced by the MCP server in
`main.py`; `server/discover` returns only `2026-07-28`, and every older
request is rejected.

## Files

```text
main.py             Strict, dependency-free MCP 2026-07-28 server
infra/main.tf       Runtime, Gateway, IAM roles, and failing DEFAULT target
infra/outputs.tf    Runtime/Gateway identifiers and runtime log group
Makefile            Apply, direct verification, logs, and cleanup
```

## Cleanup

```bash
make destroy
```

The Makefile also removes a failed target that may have been created
remotely but not recorded in Terraform state.

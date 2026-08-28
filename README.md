# AgentCore Gateway DYNAMIC listing versus a non-AgentCore MCP 2026-07-28-only target

Follow-up experiment to the DEFAULT-mode reproduction on `main` (AWS Support
case `178764595200771`, acknowledged and fixed by AWS).

## Question under test

`main` demonstrated that DEFAULT listing mode indexed targets with a legacy
`initialize @2025-11-25` conversation. DYNAMIC listing mode did **not** show
that problem for AgentCore Runtime-hosted targets: request-time discovery used
`server/discover @2026-07-28`.

A separate production observation suggests the target hosting type matters: a
strict MCP 2026-07-28 server on ECS behind a private ALB (Gateway
`managed_vpc_resource` private endpoint, DYNAMIC listing) received legacy
`initialize` requests at `tools/list` time and the Gateway returned an empty
tool list when that target failed.

This branch isolates one variable: a **non-AgentCore URL target** in DYNAMIC
mode, using the simplest such hosting — an IAM-protected Lambda Function URL.

The deployment contains exactly:

- one IAM-protected Lambda Function URL hosting a dependency-free, strict MCP
  `2026-07-28`-only server;
- two IAM-protected AgentCore Gateways advertising only `2026-07-28`, one per
  listing mode so the experiments stay isolated;
- two MCP server targets for the same Function URL — one
  `listing_mode = "DYNAMIC"`, one `listing_mode = "DEFAULT"` — with the
  Gateway IAM role signing for the `lambda` service.

The strict server rejects every older protocol version with HTTP 400 and
JSON-RPC `-32022`, and requires the 2026 per-request
`_meta` protocol version.

### Expected

`tools/list` sent to the Gateway succeeds; the Lambda log shows only
`server/discover` and `tools/list` requests carrying
`MCP-Protocol-Version: 2026-07-28` and `_meta`.

### Actual (reproduced 2026-08-28, eu-west-1)

Target creation succeeds (DYNAMIC defers discovery), but serving the first
client `tools/list` fails. The Gateway responds:

```json
{
  "content": [
    {
      "type": "text",
      "text": "ValidationException - MCP server '<function URL>' returned HTTP 400 to the initialize handshake."
    }
  ],
  "isError": true
}
```

The Lambda's CloudWatch log proves the request the Gateway sent — the same
legacy fingerprint as the fixed DEFAULT-mode issue:

```json
{
  "method": "initialize",
  "protocol_version_header": "2025-11-25",
  "mcp_method_header": null,
  "has_meta": false
}
```

For contrast, a direct signed call to the same Function URL minutes earlier
shows the compliant conversation the Lambda accepts:

```json
{
  "method": "server/discover",
  "protocol_version_header": "2026-07-28",
  "has_meta": true
}
```

So in DYNAMIC mode the request-time discovery path differs by hosting type:
AgentCore Runtime targets receive `server/discover @2026-07-28`, while plain
HTTPS URL targets (here, a Lambda Function URL; in production, an ALB/ECS
server behind a `managed_vpc_resource` private endpoint) receive the removed
legacy `initialize @2025-11-25` conversation and can never be listed.

### Completeness: DEFAULT mode against the same Function URL

The companion DEFAULT-mode target on the second gateway fails at creation
time in `eu-west-1` with the identical fingerprint (create-time indexing sent
`initialize @2025-11-25`, no `Mcp-Method`, no `_meta`), leaving the target
`FAILED`:

```text
Cause: While waiting, unexpected state 'FAILED', wanted target 'READY'.
last error: MCP server '<function URL>' returned HTTP 400 to the initialize handshake.
```

### Two-region comparison (2026-08-28)

The DEFAULT-mode fix from AWS Support case `178764595200771` was deployed to
`us-east-1` and still rolling out elsewhere, so running the same stack in
both regions isolates the fix scope from rollout lag (`terraform workspace
new us-east-1` plus `TF_VAR_aws_region`/`TF_VAR_name_prefix`):

| Path | eu-west-1 (fix not deployed) | us-east-1 (fix deployed) |
| --- | --- | --- |
| DEFAULT create-time indexing | `initialize @2025-11-25` → target `FAILED` | `server/discover` + `tools/list @2026-07-28` → target `READY` |
| DEFAULT gateway `tools/list` (client) | n/a (target failed) | returns the echo tool |
| DYNAMIC request-time discovery | `initialize @2025-11-25` → error | **still** `initialize @2025-11-25` → error |

`us-east-1` Lambda log (UTC):

```text
15:25:03  server/discover  @2026-07-28  Mcp-Method + _meta   <- DEFAULT create-time indexing (fixed)
15:25:03  tools/list       @2026-07-28  Mcp-Method + _meta   <- DEFAULT create-time indexing (fixed)
15:25:28  initialize       @2025-11-25  no Mcp-Method/_meta  <- DYNAMIC serving tools/list (still broken)
```

Conclusion: the fix covers the **create-time indexing** path for URL targets,
but the **request-time (DYNAMIC) discovery** path toward URL targets still
uses the removed legacy handshake even in the fixed region. For URL targets
the listing modes have effectively swapped roles: DEFAULT now works in fixed
regions while DYNAMIC — the previously recommended workaround — cannot list
tools at all.

## Prerequisites

- current AWS credentials for the account under test;
- AWS CLI with `bedrock-agentcore-control` support;
- Terraform;
- curl 8.10+ (`--aws-sigv4` with session-token support);
- `jq` for pretty-printing responses; and
- `uv` (only for `make verify-compliance`).

No Python dependencies or application build step are required; the deployed
server is a single stdlib file.

## Server compliance

The strict server's MCP `2026-07-28` compliance is not hand-asserted: `make
verify-compliance` drives `lambda_function.py` with the **official MCP Python
SDK** (2.x) as the client oracle through a local Function URL shim. The SDK
performs `server/discover`, `tools/list`, and `tools/call` with full typed
response validation, and the script additionally proves the strict rejections
(legacy `initialize`, missing `_meta`, `Mcp-Method` mismatch, and the
spec-mandated treatment of a missing `MCP-Protocol-Version` header as
`2025-03-26`, which is then rejected).

## Reproduce

```bash
make verify-compliance
make apply
```

DYNAMIC listing defers discovery, so its target creation succeeds; the
DEFAULT-mode target on the second gateway is expected to fail create-time
indexing (see below), which makes `make apply` exit non-zero after creating
everything else.

Optionally verify the Lambda serves strict `2026-07-28` directly:

```bash
make verify-lambda
```

Run the experiment — one `tools/list` through the Gateway:

```bash
make verify-gateway
```

Then inspect exactly what the Gateway sent to the target:

```bash
make logs
```

Relevant configuration is intentionally explicit:

```hcl
# Gateway client-facing protocol
supported_versions = ["2026-07-28"]

# Target capability mode
listing_mode = "DYNAMIC"

# Target authentication
credential_provider_configuration {
  gateway_iam_role {
    service = "lambda"
  }
}
```

## Files

```text
lambda_function.py     Strict, dependency-free MCP 2026-07-28 server (Function URL)
verify_compliance.py   Official-SDK compliance verification for lambda_function.py
main.py                Same server for AgentCore Runtime (used by the DEFAULT-mode case)
infra/main.tf          Lambda, Function URL, Gateways, IAM roles, DYNAMIC and DEFAULT targets
infra/outputs.tf       Gateway/Lambda identifiers and the Lambda log group
Makefile               Apply, direct/Gateway verification, logs, and cleanup
```

## Cleanup

```bash
make destroy
```

The Makefile also removes a target that may have been created remotely but not
recorded in Terraform state.

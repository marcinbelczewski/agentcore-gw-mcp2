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
- one IAM-protected AgentCore Gateway advertising only `2026-07-28`;
- one MCP server target using `listing_mode = "DYNAMIC"` with the Gateway IAM
  role signing for the `lambda` service.

The strict server rejects every older protocol version with HTTP 400 and
JSON-RPC `-32022`, and requires the 2026 per-request
`_meta` protocol version.

### Expected

`tools/list` sent to the Gateway succeeds; the Lambda log shows only
`server/discover` and `tools/list` requests carrying
`MCP-Protocol-Version: 2026-07-28` and `_meta`.

### Under investigation

Whether this target type instead receives a legacy conversation, as observed
with the managed-VPC/ALB/ECS target:

```json
{
  "method": "initialize",
  "protocol_version_header": "2025-11-25",
  "mcp_method_header": null,
  "has_meta": false
}
```

If the Lambda URL target passes, the failing variable narrows further to the
`managed_vpc_resource` private-endpoint path (or its missing credential
provider), and a follow-up variant should reproduce that topology.

## Prerequisites

- current AWS credentials for the account under test;
- AWS CLI with `bedrock-agentcore-control` support;
- Terraform;
- curl 8.10+ (`--aws-sigv4` with session-token support); and
- `jq` for pretty-printing responses.

No Python dependencies or application build step are required.

## Reproduce

```bash
make apply
```

DYNAMIC listing defers discovery, so apply is expected to succeed.

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
main.py                Same server for AgentCore Runtime (used by main branch)
infra/main.tf          Lambda, Function URL, Gateway, IAM roles, DYNAMIC target
infra/outputs.tf       Gateway/Lambda identifiers and the Lambda log group
Makefile               Apply, direct/Gateway verification, logs, and cleanup
```

## Cleanup

```bash
make destroy
```

The Makefile also removes a target that may have been created remotely but not
recorded in Terraform state.

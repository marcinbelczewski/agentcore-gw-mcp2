# Proposed AWS Support case

## Suggested case fields

- **Subject:** AgentCore Gateway DEFAULT target indexing cannot onboard an MCP 2026-07-28-only server
- **Service:** Amazon Bedrock AgentCore
- **Component/category:** Gateway / MCP server targets
- **Region:** eu-west-1 (also reproduced in us-east-1)
- **Severity:** General guidance / System impaired, depending on production impact

## Case description

We cannot create or synchronize an AgentCore Gateway MCP server target in
`DEFAULT` listing mode when the target accepts only MCP `2026-07-28`.

Both the Gateway and target are intentionally configured for the latest MCP
revision:

- IAM-protected AgentCore Gateway;
- Gateway `supportedVersions = ["2026-07-28"]`;
- no Gateway `sessionConfiguration`;
- IAM-protected AgentCore Runtime target;
- target `listingMode = "DEFAULT"`; and
- target `server/discover` advertises only `2026-07-28` and rejects older
  versions with HTTP 400 / JSON-RPC `-32022`.

### Expected behavior

`CreateGatewayTarget`, `UpdateGatewayTarget`, and
`SynchronizeGatewayTargets` should discover a strict `2026-07-28` server
using the stateless protocol, starting with `server/discover` and supplying
the required headers and per-request `_meta` fields.

### Actual behavior

DEFAULT-mode capability indexing sends the pre-2026 session handshake:

```text
initialize                  MCP-Protocol-Version: 2025-11-25
notifications/initialized   MCP-Protocol-Version: 2025-11-25
tools/list                  MCP-Protocol-Version: 2025-11-25
```

The initial `initialize` request has no `Mcp-Method` header and no
`params._meta`. The strict target correctly rejects it. Target creation then
fails with:

```text
Failed to connect and fetch tools from the provided MCP target server.
Error - Received error (400) from runtime.
```

In us-east-1, using a strict same-region Lambda MCP endpoint to avoid
AgentCore Runtime response wrapping, the error was more explicit:

```text
MCP server '<URL>' returned HTTP 400 to the initialize handshake.
```

The target log recorded:

```json
{
  "method": "initialize",
  "protocol_version_header": "2025-11-25",
  "mcp_method_header": null,
  "has_meta": false
}
```

The same server succeeds when invoked directly with MCP `2026-07-28`; its
`server/discover` response advertises:

```json
{"supportedVersions":["2026-07-28"]}
```

We reproduced the same legacy indexing conversation for initial target
creation, implicit refresh during target update, and explicit
`SynchronizeGatewayTargets`. Creating a new Gateway with only
`2026-07-28` configured from the start does not change the behavior.

`DYNAMIC` listing mode avoids the issue because it performs no create-time
indexing; a strict `2026-07-28` target becomes READY and can serve stateless
calls. However, DYNAMIC is not an equivalent workaround for us because we
need the DEFAULT-mode unified indexed catalog and semantic-search
interoperability.

## Minimal reproduction

Repository: **https://github.com/marcinbelczewski/agentcore-gw-mcp2**

```bash
make apply
```

The command creates the runtime and Gateway successfully, waits 30 seconds
to exclude IAM propagation, and then fails while creating the single
DEFAULT-mode target.

Optional checks:

```bash
make verify-runtime  # direct 2026-07-28 server/discover succeeds
make logs            # shows initialize @2025-11-25 from Gateway
make destroy         # removes the failed target and all resources
```

The repro contains one dependency-free Python server, one ZIP Runtime, one
Gateway, and one target. AWS provider version: `6.51.0`.

## Questions

1. Is DEFAULT-mode target indexing currently expected to use MCP
   `2025-11-25` even when the Gateway supports only `2026-07-28`?
2. Is support for creating and synchronizing strict `2026-07-28` targets in
   DEFAULT mode planned, and is there an estimated availability date?
3. Is there a supported workaround that retains DEFAULT catalog indexing
   and semantic search without requiring the target to implement the legacy
   initialize/session protocol?
4. Should the documentation clarify that `supportedVersions` applies only
   to the Gateway's client-facing endpoint and not to its DEFAULT target
   indexing protocol?

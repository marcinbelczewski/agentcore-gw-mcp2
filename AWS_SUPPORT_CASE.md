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

`DYNAMIC` listing mode avoids the issue. We verified that creating a
DYNAMIC target sends no request to the server, a strict `2026-07-28` target
becomes READY, and subsequent calls use stateless `server/discover` and
`tools/call` requests with the required headers and `_meta`. As documented,
DYNAMIC list operations are forwarded live and can be returned on separate
paginated `tools/list` pages from DEFAULT cached capabilities.

DYNAMIC is useful confirmation that IAM connectivity and the strict server
are valid, but it is not an equivalent workaround for us: it changes
capability-discovery latency and semantics and is not interoperable with
semantic search or outbound 3LO. We need DEFAULT's indexed unified catalog.

## Documentation context

We cannot find this DEFAULT/2026 incompatibility or a recommendation to use
DYNAMIC with the latest MCP version in either current source below.

The AWS blog [How AgentCore Gateway supports the MCP 2026-07-28
spec](https://aws.amazon.com/blogs/machine-learning/how-agentcore-gateway-supports-the-mcp-2026-07-28-spec/)
states:

- adopting `2026-07-28` requires "no per-target step";
- "There’s no need to re-create the gateway or make changes to individual
  gateway target configurations";
- "Tool definitions, target configuration, and inbound authentication ...
  are all unchanged by the version change"; and
- Gateway can front a target that upgrades to `2026-07-28` and translate for
  older clients.

The current [AgentCore Developer Guide — MCP server
targets](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-target-MCPservers.html)
states:

- `DEFAULT` is the listing mode unless changed;
- supported MCP protocol versions include `2026-07-28`;
- DEFAULT uses background synchronization during create, update, and
  `SynchronizeGatewayTargets` to fetch capabilities;
- DEFAULT can be used when machine-to-machine authentication is available;
  and
- DYNAMIC is presented for live/user-specific capabilities and for cases
  where no machine-to-machine credential is available, not as a requirement
  for MCP `2026-07-28` compatibility.

The guide separately describes `2026-07-28` as stateless, says clients do
not perform initialize, and says Gateway discovers capabilities through
`server/discover`. It does not warn that DEFAULT target indexing still
requires the target to implement the `2025-11-25` initialize/session
protocol.

These statements led us to expect a strict `2026-07-28` target to work in
DEFAULT mode.

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
4. Is the blog's statement that there is "no per-target step" intended to
   cover MCP server targets in DEFAULT mode, or only the Gateway's
   client-facing protocol?
5. Should the Developer Guide document that DEFAULT indexing currently
   requires the target to retain the `2025-11-25` initialize/session
   protocol even when the Gateway and target otherwise use only
   `2026-07-28`?

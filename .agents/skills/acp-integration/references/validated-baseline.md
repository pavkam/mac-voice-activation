<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Validated ACP compatibility baseline

Snapshot date: 2026-09-05. This is evidence, not an evergreen claim. Live
project code and pins are authoritative; rerun the probe before relying on a
drift-prone local or registry version.

## Local environment

| Component | Validated version |
| --- | --- |
| Cursor Agent CLI | `2026.01.23-916f423` |
| Codex CLI | `0.153.1` |
| Claude Code CLI | `2.1.220` |
| Node.js | `22.18.0` |
| npm / npx | `11.6.4` |

The native Codex and Claude CLIs exposed no ACP server subcommand. Voice
Activation correctly used the pinned npm adapters instead.

## Initialize-only probes

The exact project launch commands were run locally. Each process received only
ACP `initialize` with protocol version 1 and empty capabilities. No session was
created, no model was prompted, no permission was granted, and no login state
was changed.

- Cursor — `cursor-agent acp`: selected v1 and advertised Cursor Login,
  session loading, and prompt capabilities.
- Codex — `npx -y @agentclientprotocol/codex-acp@1.8.0`: selected v1,
  identified adapter 1.8.0, and advertised auth, session, MCP, prompt, and
  provider capabilities.
- Claude — `npx -y @agentclientprotocol/claude-agent-acp@0.73.0`: selected v1,
  identified adapter 0.73.0, and advertised session, MCP, prompt, provider, and
  extension capabilities.

Exact pinned packages were available in the local npm cache. Package metadata
showed Codex adapter 1.8.0 using ACP SDK `^1.4.0` and bundled Codex `^0.152.0`;
Claude adapter 0.73.0 used ACP SDK `1.4.0`, Claude Agent SDK `0.3.257`, and Node
`>=22`.

## Registry drift observed

On the snapshot date, npm reported Codex adapter `1.10.0` and Claude adapter
`0.75.1` as `latest`. The project pins intentionally remained at `1.8.0` and
`0.73.0`. A newer tag is compatibility-review input, not an automatic upgrade.

Refresh safely with:

```bash
.agents/skills/acp-integration/scripts/probe-local-clients.sh all
.agents/skills/acp-integration/scripts/probe-local-clients.sh all --online
```

Update this date and only the facts reproduced by the new run. Do not paste raw
initialize payloads, environment variables, credentials, or transient logs.

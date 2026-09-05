<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Claude Agent ACP adapter

Validated from the official adapter repository, its pinned release, npm
metadata, the cached package, and the installed CLIs on 2026-09-05.

## Project contract

| Item | Value |
| --- | --- |
| Preset executable | `npx` |
| Arguments | `-y @agentclientprotocol/claude-agent-acp@0.73.0` |
| ACP adapter pin | `0.73.0` |
| Required Node version | `>=22` |
| Adapter executable | `claude-agent-acp` |

The native `claude` CLI is not the configured ACP server and had no ACP
subcommand in the validated environment. The adapter is a stdio server built on
the Claude Agent SDK. Provider authentication remains outside Voice Activation.

The adapter advertises features beyond Voice Activation's current client,
including MCP, session loading, terminals, slash commands, and extensions.
Advertised support does not authorize sending optional requests: add client
behavior only after capability gating, lifecycle design, bounds, and tests.

Claude's permission extension adds optional `_meta` presentation data while the
standard `session/request_permission` request remains authoritative. Preserve
option IDs exactly, settle cancellation, and do not infer persistent provider
effects merely from a label or option kind.

The project pin remains authoritative. The npm `latest` tag was `0.75.1` on the
validation date. Its Node requirement and dependency graph can move, so a pin
upgrade needs release review, tests, and a handshake.

## Manual validation

```bash
.agents/skills/acp-integration/scripts/probe-local-clients.sh claude
.agents/skills/acp-integration/scripts/probe-local-clients.sh claude --online
```

The default probe uses npm's offline cache and sends only `initialize`. `--online`
also reads current registry metadata; it still does not prompt a model.

## Primary sources

- [Claude Agent ACP adapter](https://github.com/agentclientprotocol/claude-agent-acp)
- [Pinned v0.73.0 release](https://github.com/agentclientprotocol/claude-agent-acp/releases/tag/v0.73.0)
- [Permission extension](https://github.com/agentclientprotocol/claude-agent-acp/blob/main/docs/permission-extension.md)

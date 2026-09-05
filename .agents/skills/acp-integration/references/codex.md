<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Codex ACP adapter

Validated from the official adapter repository, its pinned release, npm
metadata, the cached package, and the installed CLIs on 2026-09-05.

## Project contract

| Item | Value |
| --- | --- |
| Preset executable | `npx` |
| Arguments | `-y @agentclientprotocol/codex-acp@1.8.0` |
| ACP adapter pin | `1.8.0` |
| Bundled Codex dependency | `@openai/codex ^0.152.0` |
| Adapter executable | `codex-acp` |

The native `codex` CLI is not the configured ACP server and had no ACP
subcommand in the validated environment. The adapter is a stdio ACP server that
starts the Codex App Server through its bundled compatible Codex package.
`CODEX_PATH` is an explicit override, not the default discovery mechanism.

The adapter can use ChatGPT login, an API key, or a configured model provider.
Voice Activation does not store those credentials. `NO_BROWSER=1` is appropriate
for noninteractive initialize probes so validation cannot open an authentication
browser.

For this preset, `ACPProcessTransport` merges a non-empty profile system prompt
into an existing JSON-object `CODEX_CONFIG` as `developer_instructions`. It must
preserve other keys and reject an existing non-object value. Never print the
full environment during debugging.

The project pin remains authoritative. The npm `latest` tag was `1.10.0` on the
validation date, so registry drift already exists. Do not change the pin without
reviewing release changes, bundled Codex compatibility, tests, and a handshake.

## Manual validation

```bash
.agents/skills/acp-integration/scripts/probe-local-clients.sh codex
.agents/skills/acp-integration/scripts/probe-local-clients.sh codex --online
```

The default probe uses npm's offline cache and sends only `initialize`. `--online`
also reads current registry metadata; it still does not prompt a model.

## Primary sources

- [Codex ACP adapter](https://github.com/agentclientprotocol/codex-acp)
- [Pinned v1.8.0 release](https://github.com/agentclientprotocol/codex-acp/releases/tag/v1.8.0)

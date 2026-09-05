<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Cursor ACP server

Validated from Cursor's official ACP documentation and the installed CLI on
2026-09-05.

## Project contract

| Item | Value |
| --- | --- |
| Preset executable | `cursor-agent` |
| Arguments | `acp` |
| Server type | Native ACP server |
| Authentication | Existing Cursor CLI login |

Cursor documents the command as `agent acp`; the installed `cursor-agent` alias
exposes the same usage and is the executable persisted by this project. Do not
silently replace the saved absolute executable with an interactive-shell alias.

The server speaks newline-delimited JSON-RPC over stdio. Its documented flow is
initialize, optional authentication, new session, prompt, streamed updates, and
permission requests. Voice Activation uses ambient CLI authentication and does
not drive Cursor's interactive login method.

Cursor also exposes extensions. The current client deliberately cancels the
blocking `cursor/ask_question` and `cursor/create_plan` requests and reports
other extensions as bounded unsupported diagnostics. Supporting an extension
requires a typed contract, cancellation behavior, bounds, and deterministic
tests; do not treat an undocumented payload as stable ACP.

Permission option identifiers are opaque. Return the exact selected ID. ACP
permission `kind` values such as `allow_once` and `reject_always` are policy
hints, not replacements for the ID.

## Manual validation

```bash
.agents/skills/acp-integration/scripts/probe-local-clients.sh cursor
```

The safe probe sends only `initialize`. For interactive troubleshooting, first
confirm `cursor-agent --version` and `cursor-agent acp --help`; authenticate with
the provider's own CLI outside Voice Activation.

## Primary source

- [Cursor ACP documentation](https://cursor.com/docs/cli/acp)

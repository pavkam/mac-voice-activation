---
name: acp-integration
description: Use when changing, reviewing, debugging, or testing ACP integration in Voice Activation, including provider presets, adapter pins, JSON-RPC framing, sessions, permissions, streaming updates, cancellation, recovery, or compatibility.
---

<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# ACP integration

Work from the repository contract, not from provider folklore.

## Load only the affected contract

| When the task touches | Read |
| --- | --- |
| JSON-RPC framing, capabilities, sessions, permissions, cancellation, recovery, bounds | `references/protocol-v1.md` |
| Tests, fakes, local probing, or completion verification | `references/testing.md` |
| Cursor's native server | `references/cursor.md` |
| The pinned Codex adapter | `references/codex.md` |
| The pinned Claude adapter | `references/claude.md` |
| A user-supplied provider | `references/custom-providers.md` |
| Pins, launch commands, compatibility drift, or the local environment | `references/validated-baseline.md` |

Load the protocol reference plus only the provider and verification material the
change needs. Do not preload every client reference.

## Follow this workflow

1. Inspect `AgentHarnessDraft`, `AgentHarnessConfiguration`, the affected ACP
   production type, its focused tests, and `docs/agent-harness.md`.
2. State the violated wire, lifecycle, security, or boundedness invariant.
3. Add the smallest failing deterministic test with `FakeACPTransport` or a
   controlled fake process. Never make unit tests require installed clients,
   credentials, network access, or a paid prompt.
4. Implement the narrow fix. Preserve direct process launch, exact JSON-RPC
   identifiers, current-session routing, ordered delivery, and cancellation.
5. Run the focused tests, then the relevant verification in
   `references/testing.md`.
6. If compatibility itself changed, run `scripts/probe-local-clients.sh`. Its
   default probe sends only `initialize`; it must not create a session, prompt a
   model, authenticate, or mutate provider state.
7. Update the provider reference, validation date, launch table, and nearby
   tests in the same change when a preset or pin changes.

## Non-negotiable rules

- ACP v1 over UTF-8 newline-delimited JSON-RPC on stdio is the supported wire.
- Stdout is protocol-only; stderr is bounded diagnostic data.
- Omitted capabilities are unsupported. Do not call an optional method merely
  because one provider happens to accept it.
- Project pins beat registry `latest`. Upgrade only through an explicit change
  with source review, deterministic tests, and an initialize-only handshake.
- Native `codex` and `claude` CLIs are not the configured ACP servers; the
  project uses pinned adapter packages.
- Never log prompts, transcripts, credentials, raw ACP payloads, or unbounded
  provider content.
- Never replay a prompt after any observable agent activity or permission
  request.

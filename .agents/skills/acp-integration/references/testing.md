<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# ACP testing and debugging

## Pick the smallest deterministic boundary

- JSON values and request IDs: `ACPJSONValueTests`, `ACPMessageTests`.
- Newline framing and size limits: `ACPLineFramerTests`.
- Update payload decoding: `ACPEventDecoderTests`.
- Handshake, prompts, and routing: `ACPClientConnection*Tests`.
- Permissions and extensions: `ACPClientConnectionPermissionTests` and
  `ACPClientConnectionLifecycleTests`.
- Process, pipes, and environment: `ACPProcessTransportTests`.
- Cache, recovery, and cancellation: `ACPAgentRunner*Tests`.
- Preset commands and discovery: `AgentHarnessConfigurationTests`,
  `WakeProfileDraftTests`, and `AgentExecutableLocatorTests`.

Use `FakeACPTransport` for exact frame order, IDs, session routing, malformed
payloads, cancellation, and provider requests. Use a short controlled local
process only for pipe and process-lifecycle behavior. Tests must not require a
provider installation, credentials, network access, or a model response.

## Regression checklist

Cover the failure before the fix. Depending on the change, assert:

- initialization rejects non-v1 responses and malformed capabilities;
- JSON-RPC identifiers retain integer, string, and null identity;
- oversized or newline-invalid frames fail within bounds;
- another session's update cannot reach the active conversation;
- updates stay ordered and delivery overflow fails closed;
- permission requests settle exactly once on select, cancel, close, and ID reuse;
- prompt cancellation cannot race into a later turn;
- startup timeouts terminate processes and pending continuations;
- missing-session retry happens once before activity and never after activity;
- stdout, stderr, stdin, and process exit drain independently; and
- diagnostics contain bounded metadata, never provider content or credentials.

## Commands

Find the exact suite name instead of guessing:

```bash
swift test list | rg 'ACP|AgentHarness|AgentExecutableLocator'
swift test --filter ACPClientConnectionPermissionTests
swift test --filter ACPProcessTransportTests
```

For a completed ACP change, run the focused test, then:

```bash
swift test
make check
git diff --check
```

Add `swift test --sanitize=thread` for actor, callback, pipe, delivery,
cancellation, or cache changes. Run an initialize-only provider probe when the
change affects compatibility, presets, package pins, startup, or framing:

```bash
.agents/skills/acp-integration/scripts/probe-local-clients.sh all
```

This probe is manual evidence, never a CI dependency. It does not validate
session creation or any model behavior.

## Battle-tested ACP failure signatures

| Symptom | Root cause to prove or reject | Regression guardrail |
| --- | --- | --- |
| “Starting the agent” never ends and Stop is inert | Active-turn identity or cancellation ownership was installed after provider startup suspended | Block startup with a controlled transport, cancel before initialization returns, and assert prompt suppression plus bounded process termination. |
| A provider-side session was removed but the app still caches it | The cached connection/session pair survived a missing-session response | Discard the pair and retry one fresh session exactly once only when no output, tool, plan, or permission activity occurred. |
| Useful streamed work appears, then the turn is reported as a connection failure | Prompt response, process exit, and stdout/stderr drain were treated as one event | Drive response, exit, and each pipe independently; drain admitted events before success or failure and preserve produced output on interruption. |
| Updates appear only after the next provider event or after pointer tracking ends | Ordered delivery was queued behind the wrong executor or run-loop mode | Measure delivery admission and `main_delivery_ms`; preserve the bounded queue and publish through the mode-aware main-run-loop bridge. |
| Permission UI remains after a choice or resolves the wrong request | A display index or reused JSON-RPC ID replaced the full turn/request identity | Key by `AgentTurnToken` plus exact request ID and settle that tuple once on selection, cancellation, close, and reuse. |

## Debug in layers

1. Inspect redacted lifecycle diagnostics and correlate connection, session,
   request, run, and turn identifiers.
2. Capture the smallest malformed frame shape without recording its content.
3. Reproduce it with a fake transport.
4. Inspect stderr separately from protocol stdout.
5. Use the local initialize probe only after deterministic behavior is covered.

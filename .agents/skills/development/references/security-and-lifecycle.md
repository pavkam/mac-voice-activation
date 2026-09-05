<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Security and lifecycle

## Trust boundaries

- Launch direct commands with `Foundation.Process`, an absolute executable URL,
  and explicit arguments. Never introduce `/bin/sh -c`, `bash -c`, evaluation,
  or implicit shell expansion.
- Provider authentication stays in provider CLIs. The optional ElevenLabs key
  stays in Keychain and may be bootstrapped only from standard input.
- `AppPreferences` stores configuration, never provider tokens or speech keys.
- Passive wake recognition requires on-device support and fails closed when the
  chosen locale cannot provide it. Interactive capture may use Apple's service.
- Treat ACP frames, subprocess output, recognition text, network responses, and
  persisted settings as untrusted input. Validate and bound before allocating or
  appending.

## Privacy contract

Never persist or log prompts, transcripts, API keys, authorization values, raw
ACP payloads/provider content, or audio. Diagnostics record typed event names,
bounded identifiers/counts, outcomes, and timing. Keep redaction at the recorder
boundary even when a caller already sanitized its fields.

Tests use inert placeholders and injected stores. They never inspect the user's
Keychain, preferences, TCC state, microphone, audio output, login items, global
hotkeys, network, authentication, paid prompts, or provider sessions.

## Identity and stale work

A retired speech session, execution, ACP turn, presentation run, narration
generation, or preview must not mutate current state. Carry the relevant
generation, run ID, session ID, turn token, request ID, or profile ID across
every suspension and callback. Invalidate identity before cancelling external
work so synchronous callbacks cannot resurrect it.

Cancellation is authoritative:

1. mark the owner cancelled or advance its generation;
2. cancel tasks/transports and close owned resources;
3. settle continuations exactly once;
4. ignore late callbacks; and
5. verify the terminal state, not only the cancellation request.

Do not replay an agent prompt after output, a permission request, or any other
observable work. Missing-session recovery may replay once only before activity.

## Bounds and ordering

Queues, diagnostics, presentation output, tool state, permission requests,
follow-ups, frames, and cached ACP sessions stay bounded. Bounds apply before
untrusted allocation or append. Preserve FIFO/causal order and backpressure when
moving work across actors, run loops, pipes, or delegates.

Process stdin, stdout, and stderr have independent lifecycles. Process exit does
not prove every pipe callback drained; one pipe closing must not hang another.
Stdout is protocol-only for ACP. Stderr is bounded diagnostics.

## Blocking and callback work

- Blocking Keychain, Service Management, filesystem, process, and pipe work must
  not occupy the main actor or Swift cooperative executor.
- Real-time audio taps do minimal work and hand buffers to a sendable sink.
- Latency-sensitive UI/audio/event delivery uses `MainRunLoopScheduler` so menus,
  drags, controls, and modal panels do not stall it.
- Framework delegates and subprocess callbacks cross into their owner through
  explicit isolation; they do not mutate view state directly.

## Battle-tested lifecycle failures

| Observable symptom | Verified boundary | Durable guardrail |
| --- | --- | --- |
| Launch or Settings appears frozen before normal startup completes | A blocking Keychain call occupied the main actor | Run Security calls on the dedicated queue, bridge with a checked continuation, and test that model initialization performs no credential read. |
| Streaming updates arrive only after a menu closes, a drag ends, or another event occurs | Delivery depended on the default run-loop mode | Re-enter through `MainRunLoopScheduler`; record `main_delivery_ms` and `run_loop_mode`, then test event-tracking delivery. |
| Passive listening dies after joining or leaving a call | The input device or audio-engine format changed under the active speech session | Observe audio-engine configuration changes, retire the old generation, and rebuild passive recognition from the new format. |
| Cancelled work later repopulates a panel, restarts speech, or completes a newer turn | Identity was invalidated after cancellation or not checked after suspension | Advance the generation/run/turn identity first, cancel owned work second, and reject every late callback in a regression test. |

These cases are not permission to add retries or sleeps. First prove which
boundary stopped progressing with paired diagnostics and one controlled test.

Use `acp-integration` for wire/session details and `voice-reading` for narration,
speech queues, provider fallback, and barge-in.

<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Testing and diagnostics

Also follow `testing-and-debugging`; this reference narrows its
authoritative workflow to spoken replies.

## Test at the smallest owner

| Change | Primary test surface |
| --- | --- |
| Spoken Markdown | `AgentMarkdownFormatterTests` |
| Boundaries, timer, fences, message identity | `AgentNarrationSegmenterTests` |
| Event eligibility and lifecycle | `AgentConversationAudioLifecycleTests`, `AgentConversationAudioActivityTests` |
| Order, lookahead, fallback, bounds, stop | `AgentSpeechQueueTests` |
| ElevenLabs HTTP shape/errors | `ElevenLabsSpeechClientTests` |
| Catalog pagination/filtering | `ElevenLabsVoiceCatalogClientTests` |
| Preview generation/cancellation | `ElevenLabsVoicePreviewPlayerTests` |
| Keychain scheduling/bootstrap policy | `AgentSpeechCredentialStoreTests`, `AgentSpeechCredentialBootstrapTests` |
| Settings/save behavior | `AppModelConversationTests`, `AppModelSettingsTests` |
| Barge-in/recognition lifecycle | `VoiceActivationCoordinatorConversationTests` and cancellation/capture suites |

Use `ControlledSpeechSynthesizer`, controlled system/audio players, presenter
spies, `SilentAgentConversationAudioPlayer`, and
`SilentAgentSpeechCredentialStore`. Extend these seams rather than introducing
real sound or service dependencies.

## Deterministic scenarios

Every queue or lifecycle change should cover the applicable cases:

1. cloud synthesis completes in submission order;
2. a later cloud request completes first but playback remains ordered;
3. synthesis fails or returns empty data and system speech receives the same
   text and locale;
4. cloud bytes cannot decode/start and system playback is selected;
5. stop cancels in-flight synthesis, active playback, and pending work;
6. late completions from a prior generation are ignored;
7. activity sound continues during `preparing`, stops at `starting`, remains
   suppressed while `playing`, and resumes only if work continues;
8. disabling reply reading cancels buffered and queued narration; and
9. no diagnostic field contains response text, headers, credentials, or audio.

Do not assert real synthesis latency, voice quality, installed voice names, or
network availability in automated tests.

## Battle-tested audio failures

| Symptom | First split in the evidence | Guardrail |
| --- | --- | --- |
| A visible sentence is silent until the next sentence arrives, then both play | If synthesis starts late, inspect segmentation/boundary delivery; if synthesis finishes early, inspect queue admission, main delivery, and playback start | Emit on punctuation, semantic boundary, message change, or the bounded first-fragment deadline; enqueue immediately and keep playback FIFO. |
| The first syllable is chopped or overlaps the working pulse | Activity audio was suppressed only after playback became audible | Keep work sound during cloud `preparing`, suppress it at `starting`, then start playback; resume only when speech is idle and agent work still exists. |
| Agent startup is silent even though the turn is visibly working | The activity flag was set only after provider initialization | Publish working state when the turn is accepted; let the delayed loop cover provider boot as well as tool work. |
| Stop cancels the provider but speech continues or a late phrase starts | Provider cancellation and narration cancellation used different ownership or stale completions remained valid | Increment the speech generation first, cancel synthesis and both players, clear pending requests, and ignore late callbacks. |
| Tests produce beeps or contact ElevenLabs | A production default adapter escaped the composition boundary | Inject silent players, controlled synthesizers, inert credentials, and URL-session fakes; assert requested effects instead of hearing them. |

Do not label the API “slow” until `speech.synthesis_started`,
`speech.synthesis_finished`, queue readiness, `playback_starting`, and delegate
completion are correlated for the same request and generation.

## Focused commands

Swift Testing filters match suite names:

```bash
swift test --filter AgentNarrationSegmenterTests
swift test --filter AgentSpeechQueueTests
swift test --filter AgentConversationAudioLifecycleTests
swift test --filter ElevenLabsSpeechClientTests
swift test --filter ElevenLabsVoiceCatalogClientTests
swift test --filter ElevenLabsVoicePreviewPlayerTests
swift test --filter AgentSpeechCredentialStoreTests
```

After focused tests, run the repository gates required by the shared verification
matrix. For a production speech change, the minimum is normally:

```bash
make check
swift test --quiet
CONFIGURATION=debug make app
codesign --verify --deep --strict .build/VoiceActivation.app
```

Do not claim a manual listening check unless a human actually heard it. Automated
checks can prove lifecycle and data flow, not perceived voice quality.

## Diagnostic vocabulary

Use the rotating JSONL log described in `docs/troubleshooting.md`. Relevant
event families are:

- `conversation_audio.*` — lifecycle, settings, working state, enqueue requests;
- `narration.*` — delta counts, boundaries, deadline delivery, buffer bounds;
- `speech.*` — queue, synthesis, fallback, playback, state, generations;
- `elevenlabs.speech_*` and `elevenlabs.voice_catalog_*` — bounded network
  timings/statuses;
- `cloud_playback.*`, `system_speech.*`, and `voice_preview.*` — framework
  playback lifecycle; and
- `credential_store.*` — queue delay and blocking-operation duration.

Correlate `request_id`/`network_request_id`, `generation`, monotonic timing,
`queue_wait_ms`, `duration_ms`, `main_delivery_ms`, and `run_loop_mode`. A start
without a finish narrows the stuck boundary. Never add payload text to make the
trace “easier”; character counts and typed event names are enough.

## Safe manual validation

Manual listening is optional and must be explicit. Use a test account/voice only
when the user intends a paid network request. Keep the sample non-sensitive,
confirm output volume first, exercise Stop/barge-in, and inspect only redacted
diagnostics. Never retrieve or print the stored Keychain value.

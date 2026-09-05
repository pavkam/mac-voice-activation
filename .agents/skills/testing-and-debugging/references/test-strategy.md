<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Test strategy

Tests use Swift Testing in two targets. Select the lowest boundary that exposes
the contract; moving a pure rule into an AppKit test merely makes the failure
slower and moodier.

## Put the test at the owning boundary

| Behavior | Test target and local pattern |
| --- | --- |
| State transitions, matching, validation, command arguments, ACP wire/lifecycle, bounded queues | `VoiceActivationCoreTests` |
| `AppModel`, presentation, layout, Settings, Keychain adapters, Service Management, hotkeys, audio, SwiftUI/AppKit | `VoiceActivationAppTests` |
| ACP frames, ordering, sessions, permissions, cancellation | `FakeACPTransport` and `ACP*TestSupport`; also read `acp-integration` |
| Process and pipe behavior | A short executable in a UUID temporary directory, as in `ACPProcessTransportTests` |
| Speech and coordinator behavior | `FakeSpeechSession`, `ControlledAgentRunner`, injected `ActivationTiming` |
| Audio, credentials, diagnostics, framework services | Silent players/stores, controlled clients, recorder spies, injected protocols |
| UI mapping and geometry | Pure presentation/layout tests before controller or rendered tests |
| Intermediate animation pixels | An isolated off-screen AppKit child process only when the transition itself is the contract |

Test types may span several `Type+ResponsibilityTests.swift` files through
extensions. Use `swift test list` rather than assuming the filename is the
suite identifier.

## Write an observable regression

1. Name the production behavior whose change would make the test fail.
2. Use the local `behavior_WhenCondition_ExpectedResult` naming style.
3. Write one `@Test` using `#expect` and `#require`; parameterize repeated
   contracts rather than copying cases.
4. Run it before the production edit. Confirm it fails because the defect is
   present, not because setup, spelling, or the environment is broken.
5. Make the smallest production change, rerun the focused test, then widen.

Use `@MainActor` for main-actor state. Preserve actor isolation in production.
Use `@Suite(.serialized)` only for a proven isolation or ordering constraint;
it serializes tests inside that suite, not unrelated suites. Prefer child
process isolation for truly process-wide state. Add a bounded `.timeLimit` to
tests that can wait on external process termination.

## Deterministic asynchronous tests

Prefer controlled continuations, actor-backed recorders, fake sleepers/clocks,
explicit gates, and observable terminal state. Existing support code includes:

- `VoiceActivationCoordinatorTestSupport.swift`
- `ACPClientConnectionTestSupport.swift`
- `ACPAgentRunnerTestSupport.swift`
- `AppModelTestSupport.swift`
- `AgentConversationAudioTestSupport.swift`

Wall-clock waits are acceptable only when elapsed time or rendered transition
progress is the behavior. Keep them short, bound the whole test, and assert the
settled state. Never add a sleep merely to let an unknown race "finish."

Tests must use UUID temporary paths and must not alter real preferences, TCC,
Keychain secrets, login items, global shortcuts, network state, audio output,
or provider sessions. Child-process fixtures launch explicit executables and
arguments; do not use a shell to make the fixture convenient.

## Command quick reference

```bash
swift test list | rg 'RelevantType|RelevantBehavior'
swift test --filter 'VoiceActivationCoreTests.WakePhraseMatcherTests'
swift test --filter 'VoiceActivationAppTests.AgentRunPresentationTests'
swift test --filter 'VoiceActivationCoreTests.WakePhraseMatcherTests/command_WhenPhraseStartsTranscript_ReturnsFollowingText'
swift test
```

`swift test --skip-build` is valid only after a successful matching test build.
Do not use it after source, flags, configuration, or toolchain changes.

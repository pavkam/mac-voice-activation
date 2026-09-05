<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Voice Activation agent guide

This file is the routing and invariant layer for agents working in this
repository. Keep it short. Load the project skill first, then only the domain
references required by the task. Live production code and tests override stale
prose; update the owning guide when behavior changes.

## Project snapshot

Voice Activation is a native SwiftPM macOS 15 menu-bar app using Swift tools
6.2, SwiftUI/AppKit, Apple Speech, Carbon hotkeys, Service Management, Keychain,
and local ACP v1 providers. Wake phrases or per-profile push-to-talk capture a
transcript, then either launch a direct executable or continue an ACP agent
conversation.

There is no app server or Voice Activation account. Passive recognition is
on-device only. Direct commands never use a shell. Provider authentication stays
with provider CLIs; the optional ElevenLabs key stays in Keychain. Sensitive
conversation content and audio never enter diagnostics.

```text
Sources/VoiceActivationCore/       State, validation, commands, ACP, preferences
Sources/VoiceActivationApp/        macOS adapters, composition, UI, audio, logs
Tests/VoiceActivationCoreTests/    Core and protocol contracts
Tests/VoiceActivationAppTests/     App, presentation, and adapter contracts
```

## Mandatory skill routing

Before changing, reviewing, debugging, or testing project code, read
`.agents/skills/development/SKILL.md`. It routes architecture,
Swift/concurrency, security/lifecycle, repository workflow, and agent-guidance
detail.

Load additional skills only when their trigger matches:

| Scope | Required skill |
| --- | --- |
| ACP framing, sessions, permissions, providers, adapters, cancellation, recovery | `.agents/skills/acp-integration/SKILL.md` |
| SwiftUI/AppKit, menu/panels, Settings, layout, styling, motion, accessibility | `.agents/skills/ux/SKILL.md` |
| Narration, macOS speech, ElevenLabs, voice catalog, playback, fallback, barge-in | `.agents/skills/voice-reading/SKILL.md` |
| Tests, diagnosis, logs, profiling, permissions, packaging, signing, CI | `.agents/skills/testing-and-debugging/SKILL.md` |

Each skill is a second-stage router. Read only the reference rows matching the
work; add another reference when the task crosses that boundary. Do not load an
entire skill tree “just in case.”

## Universal invariants

- Preserve unrelated work in a dirty tree. Never discard, overwrite, broadly
  format, or rewrite user changes to make a patch convenient.
- Put framework-independent policy in `VoiceActivationCore`; keep SwiftUI,
  AppKit, Security, Speech, Carbon, and Service Management adapters in App.
- Use `Foundation.Process` with an absolute executable and explicit arguments.
  Never add shell evaluation or treat recognized speech as shell syntax.
- A retired session, run, turn, request, task, preview, or presentation cannot
  mutate current state. Preserve identities and reject stale callbacks.
- Cancellation is authoritative. Invalidate first, cancel owned work, settle
  resources exactly once, and test terminal state.
- Keep queues, frames, diagnostics, output, follow-ups, permissions, and caches
  bounded. Preserve ordering and backpressure.
- Main-actor UI state stays isolated. Blocking foreign APIs and I/O stay off the
  main actor and Swift cooperative executor.
- Real-time audio callbacks do minimal work. Latency-sensitive delivery uses the
  existing mode-aware main-run-loop bridge.
- Menu, recording, and agent panels remain non-activating and preserve the
  foreground app's focus.
- Never log prompts, transcripts, credentials, authorization, raw provider
  content, or audio. Tests never require real secrets, network, sound, TCC,
  login items, global hotkeys, or paid prompts.

## Battle-tested triage

- Correct output arriving late is a boundary problem until proved otherwise.
  Compare provider, queue, main-run-loop, presentation, synthesis, and playback
  timestamps before blaming the API or adding concurrency.
- Stop must work before the first provider suspension. Establish run identity and
  cancellation ownership before startup, then invalidate before cancelling.
- A UI test that passes alone but crashes in the suite usually touched
  process-global AppKit state. Isolate the real window test; serialization inside
  one suite does not isolate it from other suites.
- Phase-dependent timers, sounds, actions, and copy derive from one semantic
  phase predicate. Stopping only the model timer is insufficient when SwiftUI
  owns an independent `TimelineView` or repeating effect.
- After a non-obvious verified fix, record its reusable symptom, cause, decisive
  evidence, and regression guardrail in the owning skill reference.

## Change loop

1. Inspect `git status --short`, overlapping diffs, the production owner, its
   focused tests, and the relevant project guide.
2. State the observable behavior and owning invariant. Search with `rg` before
   adding an abstraction, setting, helper, or file.
3. For behavior, write the smallest deterministic failing test and confirm the
   expected failure before production code.
4. Make one coherent change. Preserve actor isolation, identity, cancellation,
   bounds, privacy, and direct-process execution.
5. Run the focused test, then the testing skill's proportional verification
   matrix. Report manual or environment-bound rows not run.

## Repository rules

- Use four-space Swift indentation and local wrapping; no broad formatter.
- Every text source/configuration file needs the MIT SPDX header within its
  first 12 lines. Binary exceptions belong in `REUSE.toml`.
- Swift files under `Sources/` and `Tests/` have a 700-line hard limit.
- `AGENTS.md` and every text file under `.agents/skills` have a 150-line hard
  limit. Split by decision boundary; dense prose is not a loophole.
- Every public `VoiceActivationCore` symbol needs useful `///` DocC.
- This is SwiftPM. Do not create an `.xcodeproj`; change `Package.resolved` only
  when dependencies change.
- Update the relevant README or `docs/` guide with behavior, configuration,
  privacy, diagnostics, packaging, or command changes.

## Common commands

```bash
swift test list | rg '<SuiteOrTest>'
swift test --filter '<SuiteOrTest>'
swift test
CONFIGURATION=debug make app
make check
git diff --check
```

`swift run` does not validate bundle resources, `Info.plist`, signing, Keychain
identity, Service Management, or privacy grants. Use the bundled app and the
testing skill when those boundaries matter.

## Maintaining these instructions

Keep three-stage progressive disclosure:

1. this root file routes universal policy and skills;
2. each `SKILL.md` routes one domain and names exact load conditions; and
3. each reference owns one focused procedure, contract, or dated baseline.

Run `make check-agent-guidance` after editing instructions. Every project skill
must remain discoverable here, every reference must be routed by its skill, and
every guidance/helper file must stay within 150 physical lines.

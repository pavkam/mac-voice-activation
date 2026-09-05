---
name: testing-and-debugging
description: Use when testing, diagnosing, debugging, profiling, or verifying the app, including Swift failures, crashes, hangs, runtime logs, speech, audio, panels, ACP, macOS permissions, packaging, signing, or CI.
---

<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Testing and debugging

Find the violated invariant before changing code. Test the smallest observable
behavior, then widen verification in proportion to the risk.

## Load only the evidence path in use

| When the task touches | Read |
| --- | --- |
| Test placement, fakes, async control, filters, or a regression | `references/test-strategy.md` |
| Runtime logs, instrumentation, redaction, or latency fields | `references/diagnostics.md` |
| A crash, hang, flake, permission, speech, ACP, UI, or packaging symptom | `references/debugging-playbooks.md` |
| Bundle execution, LLDB, crash reports, sanitizers, Instruments, signing, TCC | `references/runtime-tools.md` |
| Toolchain, CI, test inventory, log schema, or environment drift | `references/validated-baseline.md` |
| Completion claims and proportional gates | `references/verification-matrix.md` |

Start with the symptom or test row. Load the verification matrix before the
final evidence pass, not during unrelated exploration.

For ACP work, also use `acp-integration`. For user-visible SwiftUI/AppKit,
animation, sound feedback, or accessibility work, also use
`ux`.

## Required workflow

1. Preserve evidence: inspect `git status`, the relevant diff, the complete
   error, and the active Swift/Xcode toolchain. Do not overwrite unrelated work.
2. Reproduce at the smallest boundary. Record trigger, expected result, actual
   result, and whether it is deterministic.
3. Trace backward through state, generation/run/session identifiers, callbacks,
   queues, pipes, and adapters until one root-cause hypothesis explains the
   evidence. Test one hypothesis at a time.
4. For a behavior fix, add the smallest regression test and watch it fail for
   the original reason before editing production code.
5. Implement one root-cause fix. Do not mix speculative delays, retries, actor
   weakening, or unrelated refactors into the experiment.
6. Run the focused test first, then the required rows in the verification
   matrix. Report the commands, fresh outcomes, and any manual row not run.

## Non-negotiable boundaries

- Unit tests never require a real microphone, audible output, global hotkey,
  login-item mutation, Keychain credential, provider installation, network,
  authentication, paid prompt, or the user's preferences/TCC state.
- `swift run` is not evidence for bundle resources, `Info.plist`, signing,
  Keychain identity, Service Management, or privacy grants.
- Never log or paste prompts, transcripts, credentials, authorization values,
  API keys, raw ACP payloads, provider content, or audio.
- Never reset TCC, change login items, or delete user state as a debugging
  shortcut.
- A test that passed before the fix does not prove the regression. A command
  that was not run is not a pass.

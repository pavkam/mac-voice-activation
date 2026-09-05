<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Debugging playbooks

## Universal evidence loop

1. Read the complete error, crash, test output, or structured trace.
2. Reproduce consistently and reduce the trigger.
3. Inspect the relevant diff and find a nearby working path.
4. Trace the value or event backward across each ownership boundary.
5. State one hypothesis: root cause **X** explains evidence **Y**.
6. Test one variable. If disproved, return to evidence; do not stack fixes.
7. After three failed fixes, stop and question the boundary or architecture.

## When a plausible fix changes nothing

This happened repeatedly around ACP startup and reply audio. Use this sequence
before another refactor:

1. Confirm the running PID, executable path, build configuration, and a fresh
   diagnostic `session_id`; otherwise the old bundle is answering the test.
2. Build one monotonic timeline across accepted input, provider launch/frame,
   event admission, main delivery, presentation, narration boundary, synthesis,
   playback start, and delegate completion.
3. Find the earliest large or missing interval. Downstream delay is evidence of
   an upstream wait, not evidence that every downstream component is slow.
4. If a terminal event exists without its expected visible or audible effect,
   inspect stale identity and cancellation before adding another queue.
5. If every interval is small but the user still sees a pause, profile the real
   release bundle and current run-loop mode; unit timing cannot model AppKit
   tracking by optimism alone.

The useful question is “which owner had the value and did not hand it off?”
“Can we parallelize more?” is not a diagnosis.

## Route by symptom

| Symptom | First evidence | Likely boundaries and next tool |
| --- | --- | --- |
| Compile or test failure | Complete diagnostic, `swift --version`, focused test | Source/test mismatch, actor isolation, toolchain; then CI-equivalent warning build |
| Flaky or hanging test | Exact test ID, terminal state, last fulfilled gate | Unresumed continuation, shared process state, unbounded wait; use controlled gates and `.timeLimit` |
| Runtime state is wrong | `session_id`, `sequence`, profile ID, generation/run/turn IDs | Coordinator → app model → presentation; reproduce with fake speech/runner |
| UI freezes during menu, drag, or panel input | `main_delivery_ms`, `run_loop_mode`, all-thread backtrace | Main actor, synchronous foreign work, default-mode-only scheduling; LLDB and Hangs/Time Profiler |
| App crashes or exits | Complete symbolicated crash report, termination reason, crashed thread | Read every thread and diagnostic message; use LLDB/ASan appropriate to the exception |
| Memory grows | Bounded queue/presentation counts, Allocations graph | Retained panel/task/audio/session or missing eviction; reproduce with representative stream |
| Speech does not start/recover | Permission outcome, locale, recognition generation, device format changes | `SpeechPermissions`, `AppleSpeechSession`, coordinator speech lifecycle |
| Push-to-talk misroutes | Physical key, held profile ID, press/release sequence | Hotkey event conversion → profile binding → coordinator generation |
| ACP starts, stalls, or misroutes | Redacted ACP lifecycle events, stderr metadata, exact request/session ID | Read `acp-integration`; fake transport before any local-client probe |
| Agent panel shows stale/missing output | Conversation run ID, ACP turn token, presentation run ID, delivery admission | Bounded delivery → main-run-loop bridge → presentation → panel model |
| Narration or sounds overlap/stall | Speech queue state, synthesis/playback IDs, delegate completion | Segmenter → queue → player → activity loop; use silent controlled adapters |
| Launch at Login fails | Bundle path, signature, `SMAppService.mainApp` observed state | Test injected service first; manually use a stable `/Applications` copy |
| Permission/signing/resource failure | Real bundle, `Info.plist`, signature, stable path | Build with `make app`; `swift run` is the wrong experiment |

## Concurrency-specific checks

Do not "fix" a race by adding a delay or removing actor annotations. Verify:

- the generation/run/session identifier survives every `await` and callback;
- cancellation settles tasks, continuations, pending permissions, and pipes
  exactly once;
- locks are not held across callbacks or suspension;
- stdout, stderr, stdin, process exit, and drain complete independently;
- delivery remains ordered and bounded while a consumer is slow; and
- main-actor publication remains live in default, common, modal-panel, and
  event-tracking run-loop modes.

Use Thread Sanitizer after deterministic coverage. A clean sanitizer run cannot
prove a logical ordering invariant; the regression test still carries that job.

An AppKit transition test that passes alone and crashes the complete suite in
`objc_release` or `_NSWindowTransformAnimation` has crossed a process-global
framework boundary. Run the real off-screen window assertion in an isolated
child test process. When the parent is sanitized, inject the already-loaded
`libclang_rt.*_dynamic.dylib` into the child before it loads the test bundle;
loading Thread Sanitizer after `dlopen` leaves its interceptors unusable.

## macOS state boundaries

Build and reproduce from the signed app bundle for microphone, speech, Keychain,
resources, Service Management, and menu-bar lifecycle. Do not automate TCC
resets, real login-item changes, audible output, provider authentication, or
credential import as part of diagnosis. Those mutate user state and usually
replace the bug with a second one. Charming.

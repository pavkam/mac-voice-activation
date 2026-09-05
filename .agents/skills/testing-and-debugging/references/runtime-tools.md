<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Runtime and platform tools

## Reproduce in the right artifact

For logic, start with a focused Swift test. For resources, signing, Keychain
identity, Microphone/Speech Recognition permissions, Service Management, or
menu-bar lifecycle, use the real bundle:

```bash
CONFIGURATION=debug make app
open .build/VoiceActivation.app
pgrep -fl VoiceActivation
plutil -lint .build/VoiceActivation.app/Contents/Info.plist
codesign --verify --deep --strict .build/VoiceActivation.app
```

`make app` copies the plist, icon, and sound assets, then signs and verifies the
bundle. It defaults to ad-hoc signing; rebuilds can therefore change the privacy
identity. Use an installed development identity and stable app path for repeated
manual permission testing. Never reset TCC automatically.

## LLDB

Launch the debug executable:

```bash
lldb .build/VoiceActivation.app/Contents/MacOS/VoiceActivation
```

Or find the PID with `pgrep -x VoiceActivation` and attach with
`lldb -p <PID>`. Useful commands:

```text
breakpoint set --name VoiceActivationCoordinator.pushToTalkPressed
breakpoint set --file VoiceActivationCoordinator.swift --line <line>
run
process interrupt
thread backtrace all
frame variable
po <expression>
continue
```

Break where invalid state first crosses a boundary: generation changes,
callback entry, queue admission, pipe closure, cancellation, or model
publication. On a hang, interrupt and collect all thread backtraces before
continuing.

## Crashes and runtime checks

Crash reports usually appear under:

```text
~/Library/Logs/DiagnosticReports/VoiceActivation*
```

Use the complete symbolicated report. Read termination reason, diagnostic
messages, crashed thread, and all backtraces. The last app frame is a starting
point, not a verdict.

```bash
swift test --sanitize=thread
swift test --sanitize=address
```

Use Thread Sanitizer for actors, callbacks, locks, queues, pipes, cancellation,
audio delegates, and UI delivery. Use Address Sanitizer for invalid memory
access and lifetime corruption. Sanitizers add overhead; reproduce without them
too before diagnosing a timing or performance regression.

## Instruments

Use a representative release bundle and the same interaction before and after:

- Time Profiler: CPU cost and unexpected main-thread stacks.
- SwiftUI: expensive or excessively frequent updates.
- Hangs/System Trace: blocked main run loop, waits, and priority inversions.
- Allocations/Leaks: retained panels, tasks, audio objects, transports, and
  unbounded state.

Do not profile a static preview and generalize to streaming behavior. Review
trace contents before sharing: network and other instruments may capture
sensitive values even though the app's JSONL diagnostics do not.

Primary references:

- [Swift Testing](https://developer.apple.com/documentation/testing)
- [Swift Testing parallelization](https://developer.apple.com/documentation/testing/parallelization)
- [Apple sanitizer guidance](https://developer.apple.com/documentation/xcode/diagnosing-memory-thread-and-crash-issues-early)
- [Apple responsiveness guidance](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Apple crash-report guidance](https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs)
- [LLDB tutorial](https://lldb.llvm.org/use/tutorial.html)

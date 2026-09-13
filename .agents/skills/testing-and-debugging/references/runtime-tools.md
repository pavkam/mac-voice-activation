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
open .build/YapOps.app
pgrep -fl YapOps
plutil -lint .build/YapOps.app/Contents/Info.plist
codesign --verify --deep --strict .build/YapOps.app
```

`make app` copies the plist, icon, and sound assets, then signs and verifies the
bundle. Local builds default to the persistent **YapOps Local Development**
Keychain identity; run `make setup-signing` once per Mac. CI explicitly opts into
`SIGN_IDENTITY=-`. Use the same key and app path for permission testing. Never
reset TCC yourself; `references/environment-reset.md` owns that boundary.

If Accessibility stays On in System Settings but the app reports denied, compare
the bundle's designated requirement against the one TCC stored:

```bash
codesign -d -r- .build/YapOps.app
```

Two different `cdhash` requirements confirm an ad-hoc rebuild invalidated the
grant; preserve the signing identity instead of hiding the permission action or
prompting repeatedly. A requirement pinning an unchanged certificate leaf hash
rules signing out and leaves stale TCC state as the remaining explanation —
`references/environment-reset.md` carries the 2026-09-13 evidence and the
user-run recovery. `scripts/test-build-app.py` guards the persistent default,
the explicit ad-hoc opt-in, the stable bundle directory, and preservation of the
previous `Contents/` when signing or verification fails.

## LLDB

Launch the debug executable:

```bash
lldb .build/YapOps.app/Contents/MacOS/YapOps
```

Or find the PID with `pgrep -x YapOps` and attach with
`lldb -p <PID>`. Useful commands:

```text
breakpoint set --name YapOpsCoordinator.pushToTalkPressed
breakpoint set --file YapOpsCoordinator.swift --line <line>
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
~/Library/Logs/DiagnosticReports/YapOps*
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

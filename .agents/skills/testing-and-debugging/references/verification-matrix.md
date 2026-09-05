<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Verification matrix

Run the focused regression first. Then add every row whose risk applies. Fresh
output is evidence; remembered output is nostalgia.

| Change or investigation | Required verification |
| --- | --- |
| Any behavior fix | Watch focused regression fail before the fix, then pass |
| Pure Core/model/presentation behavior | Focused suite, then `swift test` |
| AppKit/SwiftUI/macOS adapter | Focused App suite, `swift test`, `CONFIGURATION=debug make app`, affected manual flow |
| Actor, callback, lock, queue, pipe, timer, cancellation, audio delegate, delivery | Above plus `swift test --sanitize=thread` |
| Memory/lifetime corruption | Focused reproduction plus `swift test --sanitize=address`; use Allocations/Leaks when runtime-only |
| ACP | This matrix plus the required `acp-integration` matrix; local client probe only for compatibility/preset/pin/startup changes |
| UX, layout, animation, sound feedback, accessibility | This matrix plus `ux`; report unexercised manual rows |
| Resources, plist, signing, bundle, permissions, Keychain identity, login item | `make app`, plist/signature verification, real bundled flow from a stable path when relevant |
| Public Core API or Swift file structure | `make check` |
| Documentation or project skill | Skill validator where applicable, `make check`, `git diff --check` |

## CI-equivalent baseline

```bash
swift package resolve
swift build --build-tests -Xswiftc -warnings-as-errors -v
swift test --skip-build
swift test --sanitize=thread
make app
make check
git diff --check
```

CI runs repository quality, build/test, Thread Sanitizer, and package-app jobs.
The package job verifies the executable, icon, capture sounds, `Info.plist`, and
code signature. Use `swift test --skip-build` only immediately after the
matching successful build above.

## Completion report

State:

- the root cause and violated invariant;
- the regression test and why its RED failure was correct;
- each command actually run and its result;
- manual bundle/accessibility/provider rows exercised; and
- skipped or blocked rows with the concrete reason.

Do not say a sanitizer, bundle flow, or full suite passed when only a focused
test ran. If pre-existing unrelated failures remain, separate them from the
change with evidence rather than quietly adopting them.

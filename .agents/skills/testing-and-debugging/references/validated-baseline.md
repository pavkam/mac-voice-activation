<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Validated baseline

Validated locally on 2026-09-05. This file records a source-dated inventory,
not an eternal truth. Re-run the named command when the answer affects a change.

## Package and local toolchain

| Item | Validated value | Authority |
| --- | --- | --- |
| Swift tools version | 6.2 | `Package.swift` |
| Deployment target | macOS 15 | `Package.swift` |
| Swift Testing pin | `swift-6.2.2-RELEASE` revision | `Package.swift`/`Package.resolved` |
| Local Swift | Apple Swift 6.3.3, arm64 macOS 26 target | `swift --version` |
| Active developer directory | `/Library/Developer/CommandLineTools` | `xcode-select -p` |
| Local Xcode | Unavailable through the active developer directory | `xcodebuild -version` |

Full Xcode-dependent manual work such as Instruments must be run on a machine
with Xcode selected. Do not mistake that local limitation for a package defect.

## Current test inventory

`swift test list --skip-build` discovered 519 tests in 61 suites after a
successful test build:

- `VoiceActivationCoreTests`: 246 tests
- `VoiceActivationAppTests`: 273 tests

The exact count is informational and will change. Discovery, the complete
519-test run, a focused Core test, and a 29-test App presentation suite
completed successfully on the local Swift toolchain. Tests use Swift
Testing, `@MainActor` where required, `.serialized` for selected
isolation-sensitive suites, controlled in-memory ACP transports, short
real-process fixtures, silent audio/credential adapters, and an isolated
off-screen AppKit child test for an intermediate animation state.

Current `swift test --help` supports `--filter`, `--skip-build`, `--parallel`,
`--no-parallel`, `--enable-code-coverage`, `--sanitize`, and xUnit output. The
complete observed run started suites concurrently, so tests must remain
order-independent.

## Diagnostics and CI

Source inspection confirms JSONL schema version 1, a 5 MiB active log, three
rotations, 160-character event names, 120-character field keys, and
512-character single-line field values. The active local log and all three
rotations existed, and its latest record matched the documented top-level
schema. No raw record values were read into this baseline.

The current GitHub Actions workflow has four gates:

1. repository licensing, Swift file structure, and public Core DocC;
2. warning-as-error build plus complete tests;
3. complete Thread Sanitizer tests; and
4. signed app packaging and bundle verification.

`make check` passed its licensing, 700-line Swift structure, and public Core
DocC checks. `CONFIGURATION=debug make app` also built, signed, and verified the
local app bundle. Instruments was not run because the active developer
directory does not provide Xcode.

Revalidate after changes to `Package.swift`, `Package.resolved`, `Makefile`,
`.github/workflows/swift.yml`, `scripts/`, test targets/support, or either
diagnostics implementation file.

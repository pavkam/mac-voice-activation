<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Development

YapOps is a native SwiftPM macOS 15 menu-bar application using Swift
tools 6.2. Keep platform-independent policy in Core, isolate macOS frameworks in
App, and make the smallest change that proves the intended behavior.

## Prerequisites

- macOS 15 or later
- Swift 6.2 or later
- Xcode Command Line Tools or Xcode

Confirm the active toolchain before diagnosing a build difference:

```bash
swift --version
xcode-select -p
xcodebuild -version
```

The command-line tools can build and test the package. Full Xcode is required
for Instruments and other Xcode-only manual workflows.

## Repository layout

```text
Sources/YapOpsCore/       State, validation, commands, ACP, preferences
  Profiles/                        Profile identity and validation
  TextToSpeech/                    Persisted backend and voice selections
Sources/YapOpsApp/        macOS adapters, composition, UI, audio, logs
  Profiles/                        Profile presentation and editing models
  Settings/                        Settings composition and profile editors
  TextToSpeech/                    Registry, adapters, credentials, playback
Tests/YapOpsCoreTests/    Core behavior and protocol contracts
Tests/YapOpsAppTests/     App, presentation, and adapter contracts
Sources/YapOpsApp/Resources/ Bundle plist, icon, and sounds
scripts/                           Packaging and repository checks
.github/workflows/swift.yml        Build, test, sanitizer, and packaging CI
docs/                              User, architecture, operations, and contributor guides
```

`Package.swift` declares the two production targets, their test targets, and
external dependencies. This repository does not use or generate an Xcode
project.

## Common commands

```bash
make build                 # Debug SwiftPM build
make test                  # Complete test suite
make setup-signing         # Once per Mac: create/reuse local Keychain identity
make app                   # Release app bundle, signed and verified
make run                   # Build and open the app bundle
make check-license         # SPDX, MIT, binary metadata, and app copyright
make check-agent-guidance  # Guidance routing and 150-line limit
make check-structure       # 700-line Swift source and test limit
make check-documentation   # Public YapOpsCore DocC coverage
make check-packaging       # Isolated packaging tests; no real signing or Keychain
make check                 # All repository quality checks
```

Use [Testing](testing.md) for focused filters, sanitizers, CI-equivalent
verification, and evidence reporting. Use [Packaging](packaging.md) for debug
bundles, signing identities, resources, installation, and Launch at Login.

## Make a focused change

1. Inspect `git status --short`, overlapping diffs, the production owner, its
   focused tests, and the required project skill references.
2. State the observable behavior and owning invariant. Search with `rg` before
   adding a helper, abstraction, setting, or file.
3. For behavior, write the smallest deterministic regression and confirm it
   fails for the expected reason.
4. Make one coherent change while preserving identity, cancellation, ordering,
   bounds, privacy, actor isolation, and direct-process execution.
5. Run the focused test, then widen verification according to risk. Inspect the
   resulting diff and preserve unrelated work.

Live production code and tests override stale prose. Do not weaken a contract to
make a test easier or add guessed sleeps to make an asynchronous race quieter.

## Source conventions

- Use four-space Swift indentation and local wrapping. Do not run a broad
  formatter over unrelated code.
- Keep every Swift file under `Sources/` and `Tests/` at or below 700 physical
  lines. Split at an ownership or behavior boundary before reaching the limit.
- Put framework-independent policy in `YapOpsCore`. Keep SwiftUI,
  AppKit, Security, Speech, Carbon, Service Management, and concrete audio or
  filesystem adapters in `YapOpsApp`.
- Keep main-actor presentation state isolated. Move blocking foreign APIs and
  I/O off the main actor and Swift cooperative executor.
- Use `Foundation.Process` with an absolute executable and explicit arguments.
  Never introduce shell evaluation for recognized or provider-controlled text.
- Add the MIT SPDX header within the first 12 lines of every text source or
  configuration file. Annotate non-commentable binaries in `REUSE.toml`.
- Change `Package.resolved` only when dependencies intentionally change. Do not
  create an `.xcodeproj`.

See [Architecture](architecture.md) and
[Concurrency and lifecycle](concurrency-and-lifecycle.md) for subsystem and
asynchronous ownership.

## Public Core documentation

Every public `YapOpsCore` symbol needs a useful `///` DocC comment.
Document purpose, ownership, concurrency, side effects, failure, parameters,
and results where relevant instead of restating the declaration.

`make check-documentation` builds a public symbol graph and rejects undocumented
Core symbols, including public cases, properties, initializers, and methods.
Internal architectural boundaries also benefit from documentation; obvious
private implementation and SwiftUI composition do not need ceremonial prose.

## Update the owning guide

Update documentation in the same change when behavior, configuration, privacy,
diagnostics, packaging, commands, or provider contracts move. Give a detailed
default, limit, or lifecycle rule one canonical owner and link to it elsewhere.

Project agent guidance uses three-stage progressive disclosure: root invariants
in `AGENTS.md`, domain routing in each `SKILL.md`, and focused procedures in
skill references. Keep root and skill text at or below 150 physical lines and
run `make check-agent-guidance` after changing it.

`.agents/skills` holds the only copy of those skills. `.claude/skills` and
`.cursor/skills` are committed relative symlinks to it, so Claude Code, Cursor,
and any other assistant reading a conventional path get the same library and it
cannot drift. Edit the canonical path; never copy a skill into a runtime
directory.

See [Documentation](documentation.md) for ownership, terminology, evidence, and
the review checklist.

## Related guides

- [Architecture](architecture.md)
- [Concurrency and lifecycle](concurrency-and-lifecycle.md)
- [Testing](testing.md)
- [Packaging](packaging.md)
- [Documentation](documentation.md)
- [Diagnostics](diagnostics.md)

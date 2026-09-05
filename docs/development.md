<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Development

## Repository layout

```text
Sources/VoiceActivationCore/       Platform-independent behavior
Sources/VoiceActivationApp/        macOS adapters and SwiftUI application
Tests/VoiceActivationCoreTests/    Coordinator and command unit tests
Tests/VoiceActivationAppTests/     macOS adapter unit tests
scripts/build-app.sh               Application bundle assembly and signing
scripts/check-license-headers.sh   MIT and SPDX metadata validation
scripts/check-agent-guidance.sh    Agent instruction routing and size validation
scripts/check-swift-structure.sh   Seven-hundred-line Swift file limit
scripts/check-swift-documentation.swift Public DocC coverage validation
.github/workflows/swift.yml        Build, test, and packaging CI
LICENSE                            User-facing MIT license text
REUSE.toml                         Metadata for non-commentable tracked files
```

The package targets macOS 15 and uses Swift tools version 6.2. Swift Testing is
pinned through `Package.resolved`.

## Common commands

```bash
make build         # Debug build
make test          # Complete test suite
make app           # Release app bundle with verification
make run           # Build and launch the app bundle
make check-license # MIT, SPDX, and app metadata validation
make check-agent-guidance # 150-line agent-guidance and routing validation
make check-structure # Swift source and test file size validation
make check-documentation # Public VoiceActivationCore DocC coverage
make check         # Complete repository metadata and structure validation
```

For the same debug sequence used by continuous integration:

```bash
swift package resolve
swift build --build-tests -Xswiftc -warnings-as-errors -v
swift test --skip-build
```

Concurrency-sensitive changes must also pass Thread Sanitizer:

```bash
swift test --sanitize=thread
```

## App bundle

`scripts/build-app.sh` builds the `VoiceActivation` product, creates the macOS
bundle layout, copies `Info.plist`, signs the result, and verifies the signature.

Two environment variables are supported:

- `CONFIGURATION` defaults to `release` and selects the Swift build
  configuration passed to `swift build -c`.
- `SIGN_IDENTITY` defaults to `-`, which requests ad-hoc signing. Set it to an
  installed code-signing identity for stable development signing.

The final bundle is `.build/VoiceActivation.app`.

## Tests

Tests use Swift Testing and are split at the production-module boundary. The
coordinator suite uses a deterministic speech-session fake and short injected
timings to cover:

- multi-profile wake matching, routing, and command transitions;
- paused and continuous speech;
- inactivity and maximum capture timeouts;
- push-to-talk preemption;
- recognition startup and runtime recovery;
- stale callback rejection;
- command execution and passive-listening resumption; and
- same-session agent follow-ups, mid-turn interruption, idle voice exit, and
  speech-output echo rejection.

Core ACP suites use in-memory transports and real child-process fixtures to
cover framing at every split point, all stable update kinds, exact JSON-RPC
identifiers, permissions, authentication, cancellation, concurrent pipe exit,
bounded event delivery, lifecycle races, caching, and global run preemption.
The same suites prove exact session routing, bounded least-recently-used profile
caching, one-shot recovery when a provider forgets a session, and refusal to
replay a prompt after observable agent activity. Coordinator coverage verifies
that a late provider failure preserves streamed output, leaves conversation
capture active, and sends the next utterance through a fresh run.

App adapter tests use an injected login-item service to verify successful and
failed Service Management registration without changing the developer Mac's
real login items.

Overlay tests keep the AppKit window behind a display boundary and verify that
capturing shows partial text and the selected accent while every non-capturing
state hides the panel. Sound-presenter tests prove exactly one cue per capture
edge.
Coordinator tests separately prove live text publication for wake and
push-to-talk capture.

Agent-panel tests verify run-identifier isolation, UTF-8-safe output and
diagnostic bounds, tool eviction, simultaneous permissions, 20 Hz token
coalescing, exact-once cancellation, menu affordances, overlay handoff geometry,
bottom-pinned automatic scrolling throughout user interaction, bounded and
chronological follow-ups, per-turn plans, thought-free separated response export,
terminal tool settlement, and a panel that accepts pointer actions without
becoming key or main. Conversation-audio tests use injected silent players and
an injected ElevenLabs transport to verify bounded-latency streaming flushes,
ordered synthesis prefetch, stale-request cancellation, cloud failure fallback,
Markdown formatting, permission resume, deduplicated tool-transition cues, and
playback-only thinking-pulse suppression. Placement tests verify that the
top-right notification restores the saved expanded frame. Every audio test uses
spies and produces no sound or network traffic from the test process.
App tests cover pause and
shutdown races during pending permission requests plus profile-identified hotkey
releases. Hotkey recording tests synthesize AppKit events without registering
global shortcuts.

Automated local provisioning may invoke the signed app once with
`--store-elevenlabs-key-from-stdin`. The process reads exactly one credential
line from standard input, stores it in Keychain under the app's own identity,
and exits before creating the menu-bar UI. The credential must never be supplied
as a command-line argument, environment value, fixture, or repository file.

Run one suite while iterating:

```bash
swift test --filter VoiceActivationCoordinatorTests
```

## Swift source conventions

Every Swift file under `Sources/` and `Tests/` is limited to 700 physical
lines. Split files at responsibility boundaries before they reach that limit;
there is no blanket exception for views. The checker has no exception list:
SwiftUI code must also be decomposed by retained view responsibility when it
approaches the limit.

Use Swift documentation comments (`///`) for modules' public APIs and for
internal types or members that form an architectural boundary. Document intent,
ownership, concurrency, side effects, and failure behavior rather than restating
the declaration. Use DocC field syntax such as `- Parameters:`, `- Returns:`,
and `- Throws:` when the contract needs it. `make check-documentation` extracts
the compiler's symbol graph and rejects every undocumented public Core symbol,
including cases, properties, initializers, and methods. Private implementation
details and obvious SwiftUI composition properties use ordinary comments only
when the reasoning is not clear from the code.

## Continuous integration

The `🎙️ Swift CI` workflow runs for pushes and pull requests targeting `main`.

1. `⚖️ Repository quality` verifies the MIT license, SPDX headers, binary
   annotations, app copyright metadata, Swift file-size limit, and complete
   public Core DocC coverage.
2. `🧪 Build & test` resolves dependencies, builds the app and tests, then runs
   the complete suite.
3. `🧵 Thread sanitizer` runs the complete suite with race instrumentation.
4. `📦 Package app` runs only after all prerequisite jobs pass, builds the signed
   bundle, checks `Info.plist`, verifies the executable, and verifies the code
   signature.

Workflow permissions are read-only, duplicate runs on the same branch are
cancelled, and every job has an explicit timeout.

## Change checklist

Before pushing:

```bash
swift test
make app
make check
git diff --check
```

Update the relevant guide whenever behavior, configuration, privacy boundaries,
packaging, or development commands change.

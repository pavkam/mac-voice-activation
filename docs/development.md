# Development

## Repository layout

```text
Sources/VoiceActivationCore/       Platform-independent behavior
Sources/VoiceActivationApp/        macOS adapters and SwiftUI application
Tests/VoiceActivationCoreTests/    Coordinator and command unit tests
Tests/VoiceActivationAppTests/     macOS adapter unit tests
scripts/build-app.sh               Application bundle assembly and signing
.github/workflows/swift.yml        Build, test, and packaging CI
```

The package targets macOS 15 and uses Swift tools version 6.2. Swift Testing is
pinned through `Package.resolved`.

## Common commands

```bash
make build   # Debug build
make test    # Complete test suite
make app     # Release app bundle with verification
make run     # Build and launch the app bundle
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
- stale callback rejection; and
- command execution and passive-listening resumption.

App adapter tests use an injected login-item service to verify successful and
failed Service Management registration without changing the developer Mac's
real login items.

Overlay tests keep the AppKit window behind a display boundary and verify that
capturing shows partial text and the selected accent while every non-capturing
state hides the panel. Sound-presenter tests prove exactly one cue per capture
edge.
Coordinator tests separately prove live text publication for wake and
push-to-talk capture.

Run one suite while iterating:

```bash
swift test --filter VoiceActivationCoordinatorTests
```

## Continuous integration

The `🎙️ Swift CI` workflow runs for pushes and pull requests targeting `main`.

1. `🧪 Build & test` resolves dependencies, builds the app and tests, then runs
   the complete suite.
2. `📦 Package app` runs only after tests pass, builds the signed bundle, checks
   `Info.plist`, verifies the executable, and verifies the code signature.

Workflow permissions are read-only, duplicate runs on the same branch are
cancelled, and each job has a 15-minute timeout.

## Change checklist

Before pushing:

```bash
swift test
make app
git diff --check
```

Update the relevant guide whenever behavior, configuration, privacy boundaries,
packaging, or development commands change.

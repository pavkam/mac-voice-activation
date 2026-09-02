# Voice Activation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menu-bar app that recognizes a wake phrase or push-to-talk speech and invokes one configured executable with the transcription as argument data.

**Architecture:** A main-actor coordinator exclusively owns a replaceable Apple Speech session and translates callbacks into a small public state machine. Pure matcher and command-template values isolate text and safety rules; SwiftUI projects coordinator state into a menu and settings window.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, Carbon, AVFoundation, Speech, Swift Testing, Swift Package Manager.

**Spec:** `docs/superpowers/specs/2026-09-02-voice-activation-design.md`

## Global Constraints

- Support macOS 15 or later.
- Passive recognition must set `requiresOnDeviceRecognition = true` and fail closed when unavailable.
- Invoke an absolute executable directly with `Process`; never invoke a shell.
- Treat transcript expansion as individual argv values and support `{text}` and `{urlText}`.
- Keep passive wake and push-to-talk mutually exclusive through one coordinator.
- Package an `LSUIElement` app bundle with microphone and speech usage descriptions.

---

### Task 1: Pure wake and command domain

**Files:**
- Create: `Package.swift`
- Create: `Sources/VoiceActivationCore/ActivationState.swift`
- Create: `Sources/VoiceActivationCore/WakePhraseMatcher.swift`
- Create: `Sources/VoiceActivationCore/CommandTemplate.swift`
- Create: `Tests/VoiceActivationCoreTests/WakePhraseMatcherTests.swift`
- Create: `Tests/VoiceActivationCoreTests/CommandTemplateTests.swift`

**Interfaces:**
- Produces: `ActivationState`, `WakePhraseMatcher.command(in:wakePhrase:) -> String?`, `CommandTemplate.init(executablePath:argumentTemplates:)`, and `expandedArguments(for:)`.

- [ ] **Step 1: Add failing matcher tests** for case-insensitive matching, word boundaries, punctuation, multi-word phrases, trigger-only input, and command extraction.
- [ ] **Step 2: Run `swift test --filter WakePhraseMatcherTests`** and verify the missing symbols fail compilation.
- [ ] **Step 3: Implement normalized literal phrase matching** using Foundation localized/diacritic-insensitive comparison and alphanumeric boundaries.
- [ ] **Step 4: Add failing command-template tests** for absolute executable validation, literal text insertion, RFC 3986 query encoding, and shell metacharacters remaining within one argument.
- [ ] **Step 5: Run `swift test --filter CommandTemplateTests`** and verify failure for the missing type.
- [ ] **Step 6: Implement `CommandTemplate`** with `ValidationError`, executable checks, and per-argument replacement.
- [ ] **Step 7: Run both focused suites** and verify they pass.
- [ ] **Step 8: Commit** with `feat: add wake matching and command templates`.

### Task 2: Preferences and process execution

**Files:**
- Create: `Sources/VoiceActivationCore/AppPreferences.swift`
- Create: `Sources/VoiceActivationCore/CommandRunner.swift`
- Create: `Tests/VoiceActivationCoreTests/AppPreferencesTests.swift`
- Create: `Tests/VoiceActivationCoreTests/CommandRunnerTests.swift`

**Interfaces:**
- Consumes: `CommandTemplate`.
- Produces: `AppPreferences` typed persisted values; `CommandRunning.run(template:transcript:) async throws -> CommandResult`; concrete `CommandRunner`.

- [ ] **Step 1: Add failing isolated-defaults tests** for defaults and round-trip persistence.
- [ ] **Step 2: Run `swift test --filter AppPreferencesTests`** and verify the type is missing.
- [ ] **Step 3: Implement typed `UserDefaults` access** with the exact defaults from the spec and normalized wake/locale values.
- [ ] **Step 4: Add failing runner tests** using `/usr/bin/printf` for success and a temporary non-executable path for validation failure.
- [ ] **Step 5: Run `swift test --filter CommandRunnerTests`** and verify the runner is missing.
- [ ] **Step 6: Implement direct `Process` launch** with async termination, standard streams redirected to null, and non-zero exit reporting.
- [ ] **Step 7: Run both focused suites** and verify they pass.
- [ ] **Step 8: Commit** with `feat: persist configuration and execute commands safely`.

### Task 3: Coordinator state machine

**Files:**
- Create: `Sources/VoiceActivationCore/SpeechSession.swift`
- Create: `Sources/VoiceActivationCore/VoiceActivationCoordinator.swift`
- Create: `Tests/VoiceActivationCoreTests/VoiceActivationCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ActivationState`, `AppPreferences`, and `CommandRunning`.
- Produces: `SpeechSessionProtocol.start(mode:localeID:onUpdate:)`, `SpeechUpdate`, `VoiceActivationCoordinator.setPassiveEnabled(_:)`, `pushToTalkPressed()`, `pushToTalkReleased()`, state and last-transcript callbacks.

- [ ] **Step 1: Add fake speech and runner implementations plus failing transition tests** for passive start, wake command dispatch, trigger-only capture, PTT preemption, release dispatch, empty transcript, and passive resume.
- [ ] **Step 2: Run `swift test --filter VoiceActivationCoordinatorTests`** and verify missing symbols fail compilation.
- [ ] **Step 3: Implement the main-actor coordinator** with generation rejection, a 1.5-second inactivity task, 30-second hard stop, command cooldown, and deterministic stop/restart.
- [ ] **Step 4: Run the focused coordinator suite** and verify all transitions pass.
- [ ] **Step 5: Commit** with `feat: coordinate wake and push-to-talk flows`.

### Task 4: Apple Speech and permissions adapter

**Files:**
- Create: `Sources/VoiceActivationApp/AppleSpeechSession.swift`
- Create: `Sources/VoiceActivationApp/SpeechPermissions.swift`
- Create: `Tests/VoiceActivationAppTests/SpeechRequestPolicyTests.swift`

**Interfaces:**
- Consumes: `SpeechSessionProtocol` and `SpeechUpdate`.
- Produces: `AppleSpeechSession` and `SpeechPermissions.request() async -> Bool`.

- [ ] **Step 1: Add request-policy tests** proving passive requests require on-device recognition while PTT requests allow the recognizer default.
- [ ] **Step 2: Run the focused suite** and verify policy symbols are absent.
- [ ] **Step 3: Implement authorization bridging** for microphone and speech-recognition permission.
- [ ] **Step 4: Implement `AppleSpeechSession`** with `AVAudioEngine`, partial results, input-format validation, stale callback generations, on-device fail-closed behavior, and idempotent cleanup.
- [ ] **Step 5: Run `swift test`** and verify all suites pass without accessing the microphone.
- [ ] **Step 6: Commit** with `feat: add native speech recognition session`.

### Task 5: Menu-bar app and configurable push-to-talk

**Files:**
- Create: `Sources/VoiceActivationApp/VoiceActivationApp.swift`
- Create: `Sources/VoiceActivationApp/AppModel.swift`
- Create: `Sources/VoiceActivationApp/MenuContentView.swift`
- Create: `Sources/VoiceActivationApp/SettingsView.swift`
- Create: `Sources/VoiceActivationApp/PushToTalkShortcut.swift`
- Create: `Sources/VoiceActivationApp/Resources/Info.plist`

**Interfaces:**
- Consumes: all core interfaces and `AppleSpeechSession`.
- Produces: the `VoiceActivation` executable and its Settings/menu UI.

- [ ] **Step 1: Implement `AppModel` wiring** for preferences, permissions, coordinator output, passive toggle, PTT callbacks, and settings persistence/restart.
- [ ] **Step 2: Implement Carbon global-hotkey handlers** for Control-Option-Space with separate key-down/key-up actions.
- [ ] **Step 3: Implement the `MenuBarExtra`** with state-dependent SF Symbol, state text, last transcript/error, toggle, Settings, and Quit.
- [ ] **Step 4: Implement Settings** for wake phrase, locale, executable, argument lines, shortcut recorder, privacy note, and save validation.
- [ ] **Step 5: Run `swift build` and `swift test`** and fix all strict-concurrency/compiler findings.
- [ ] **Step 6: Commit** with `feat: add menu bar and settings experience`.

### Task 6: Packaging and end-to-end verification

**Files:**
- Create: `scripts/build-app.sh`
- Create: `Makefile`
- Create: `README.md`
- Create: `.gitignore`

**Interfaces:**
- Consumes: release `VoiceActivation` executable and Info.plist.
- Produces: `.build/VoiceActivation.app` and documented build/run workflow.

- [ ] **Step 1: Add a packaging script** that builds release, assembles the bundle, ad-hoc signs, and verifies Info.plist keys.
- [ ] **Step 2: Add Make targets** for `build`, `test`, `app`, and `run`.
- [ ] **Step 3: Document setup, permissions, configuration, URL examples, privacy behavior, and known ad-hoc-signing permission persistence limits.**
- [ ] **Step 4: Run `swift test`, `swift build -c release`, `make app`, `plutil -lint`, `codesign --verify --deep --strict`, and inspect the bundle executable.**
- [ ] **Step 5: Run `git diff --check` and inspect `git status --short`.**
- [ ] **Step 6: Commit** with `build: package voice activation app`.

# Architecture

Voice Activation separates testable speech and command behavior from macOS UI
and framework adapters.

## Modules

- `VoiceActivationCore` owns wake matching, state transitions, command
  templates, process execution, and preferences.
- `VoiceActivationApp` owns the SwiftUI menu and Settings window, Apple speech
  capture, privacy requests, and Carbon global shortcut.
- `VoiceActivationCoreTests` covers pure coordinator, matcher, template,
  runner, and preference behavior.
- `VoiceActivationAppTests` covers macOS adapter policies, audio callback
  isolation, menu status, and Settings presentation.

`AppModel` is the main-actor bridge between SwiftUI and
`VoiceActivationCoordinator`. The coordinator owns exactly one active speech
session and invalidates callbacks from retired sessions with a generation
identifier.

## State flow

```mermaid
stateDiagram-v2
    [*] --> Disabled
    Disabled --> Listening: Enable passive mode
    Listening --> Capturing: Wake phrase
    Disabled --> Capturing: Push-to-talk pressed
    Listening --> Capturing: Push-to-talk pressed
    Capturing --> Executing: Non-empty transcript
    Capturing --> Listening: Empty transcript or timeout
    Executing --> Listening: Command finishes
    Listening --> Failed: Recognition or configuration error
    Capturing --> Failed: Recognition or configuration error
    Executing --> Failed: Command error
    Failed --> Listening: Recoverable restart
    Listening --> Disabled: Disable passive mode
```

The visible menu-bar state is `Disabled`, `Listening`, `Capturing`, `Running
command`, or an error message.

## Speech modes

- **Passive wake:** the always-listen toggle starts on-device recognition. It
  restarts after final results and recoverable failures.
- **Command capture:** a wake phrase finalized alone starts recognition that
  may use Apple's speech service. It finishes on a final result, 1.5 seconds of
  inactivity, or the 30-second maximum.
- **Push to talk:** Control-Option-Space starts recognition that may use Apple's
  speech service. Releasing the shortcut finishes capture.

When the wake phrase and command arrive in one transcription, the coordinator
uses the remaining text immediately. When the wake phrase finalizes alone, it
starts a dedicated command session so pausing after `computer` does not discard
the next utterance.

## Command execution

`CommandTemplate` validates two invariants before settings are saved:

1. The executable path is absolute.
2. At least one argument contains `{text}` or `{urlText}`.

`CommandRunner` verifies that the file is executable, expands each argument,
starts `Foundation.Process`, discards process standard streams, and treats a
non-zero exit status as an error. No shell parses the transcript.

## Concurrency and lifecycle

- Coordinator and app-model mutation is isolated to the main actor.
- The real-time audio tap appends buffers through a sendable sink without
  crossing into main-actor state.
- Mode changes cancel inactivity and maximum-duration tasks, stop the audio
  engine, remove its input tap, and cancel the recognition task.
- Recognition callbacks carry a session generation and are ignored after that
  session is stopped.
- Command execution runs asynchronously and returns to passive listening after
  a short cooldown.

## Privacy boundary

Passive wake recognition sets `requiresOnDeviceRecognition` and refuses to run
when the locale lacks on-device support. Interactive command capture can use
Apple's speech service. Audio is not stored; only the most recent command text
is retained in memory for menu feedback.

Next: [development and verification](development.md).

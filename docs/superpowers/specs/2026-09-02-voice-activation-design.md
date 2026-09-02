# Voice Activation macOS App Design

## Purpose

Voice Activation is a small macOS menu-bar app that turns speech into one
configured process invocation. It supports two entry paths:

- passive wake phrase detection followed by a spoken command; and
- a global push-to-talk shortcut held while speaking.

The app keeps speech processing on the Mac whenever it listens passively and
does not depend on a server, account, browser extension, or shell.

## Scope

The app uses `AVAudioEngine` capture, `SFSpeechRecognizer` transcription,
on-device enforcement for passive wake, explicit microphone and speech
permissions, global push-to-talk handling, and a menu-bar lifecycle. Server,
chat, synchronization, TTS, device-selection, and overlay features are outside
its deliberately narrow scope.

## Platform and packaging

- Swift 6.2 language mode and macOS 15 or later.
- Swift Package Manager owns sources, tests, and the single third-party package.
- Carbon's global hotkey API supplies push-to-talk without a third-party runtime.
- A packaging script assembles `.build/VoiceActivation.app`, adds the required
  privacy descriptions, marks the app as a menu-bar agent, and ad-hoc signs it
  for local development.
- The application has no Dock icon (`LSUIElement` is true).

## User experience

The menu-bar icon communicates the current state: disabled, listening,
capturing, executing, or error. Its menu contains:

- an enable/disable passive-listening toggle;
- the current state and last recognized command;
- a Settings action;
- a Quit action.

Settings contain:

- wake phrase (default `computer`);
- speech locale (default is the current locale);
- executable path;
- one argument-template value per line;
- the push-to-talk shortcut (Control-Option-Space);
- launch-at-login is out of scope for the first version.

Passive listening defaults to enabled on first launch so the app begins its
intended always-listening behavior as soon as permissions are granted.

The default command demonstrates URL invocation without assuming the user's
eventual target:

- executable: `/usr/bin/open`
- argument: `https://www.google.com/search?q={urlText}`

`{text}` inserts the transcript as one literal argument. `{urlText}` inserts
the transcript encoded as a URL-query value. Templates are never evaluated by
a shell. Settings are persisted through `UserDefaults`.

## Voice state machine

`VoiceActivationCoordinator` is the sole owner of the active microphone mode.
Its externally visible states are disabled, listening, capturing, executing,
and failed.

When passive listening is enabled:

1. The coordinator verifies microphone and speech-recognition permission.
2. It verifies that the selected locale supports on-device recognition.
3. It starts an on-device recognition task with partial results.
4. `WakePhraseMatcher` matches the configured phrase case-insensitively at a
   word boundary and returns any text following the phrase.
5. Once triggered, the current recognition stream collects any immediately
   following command text. If the wake phrase finalizes alone, a dedicated
   command-capture stream starts so a natural pause does not lose the command.
   Capture ends on a final result or 1.5 seconds of transcript inactivity, and
   a 30-second hard limit prevents an unbounded capture.
6. Non-empty text is sent to `CommandRunner`, then passive listening restarts
   after a short cooldown.

Recognition tasks may end even while the app remains enabled. Normal final or
recoverable error completion schedules a bounded restart. Permission failure,
unsupported on-device recognition, or invalid configuration moves the app to
failed state and leaves a useful message in the menu.

Push-to-talk preempts passive listening. Key-down pauses passive recognition
and starts interactive transcription; key-up finalizes the request and invokes
the command with the best non-empty transcript. The coordinator then resumes
passive listening if it is enabled. Repeated key events and stale recognition
callbacks are ignored by generation identifiers.

## Components

- `VoiceActivationApp`: SwiftUI app entry point, menu-bar scene, and Settings
  scene.
- `AppModel`: main-actor observable projection of preferences, state, last
  transcript, and user actions.
- `VoiceActivationCoordinator`: serializes passive wake and push-to-talk modes,
  owns restart/cooldown tasks, and publishes state changes.
- `SpeechRecognizerSession`: wraps `AVAudioEngine`, recognition request/task,
  permissions, partial results, finalization, and deterministic teardown.
- `WakePhraseMatcher`: pure Unicode-aware wake phrase normalization and command
  extraction.
- `CommandTemplate`: validates executable and expands argument templates.
- `CommandRunner`: launches `Process` directly and reports launch/exit errors.
- `AppPreferences`: typed `UserDefaults` persistence with validated defaults.
- `PushToTalkShortcut`: connects Carbon hotkey key-down/key-up callbacks
  to the coordinator.

## Safety and privacy

Passive wake requests require on-device recognition. The app refuses to enable
passive mode for a locale that would send audio to a service. Push-to-talk uses
Apple's interactive recognizer and may use Apple's service when on-device
recognition is unavailable; Settings explains this distinction.

The command is executed without `/bin/sh`, `zsh`, AppleScript, or string
concatenation. Transcript content remains one argument value after template
expansion. The executable must be an absolute, executable file. Empty
transcripts do nothing. The app does not persist audio; it stores only the most
recent transcript for menu feedback.

## Errors and lifecycle

All audio taps, recognition requests, recognition tasks, timers, and shortcut
handlers are removed on mode changes and app termination. Startup errors are
shown through state rather than crashing. A process launch failure or non-zero
exit is shown as the last command error but does not permanently stop passive
listening.

## Testing and acceptance

Pure unit tests cover:

- wake phrase matching, boundaries, punctuation, case, and multi-word phrases;
- argument expansion, URL encoding, validation, and shell-like transcript text;
- coordinator transitions using fake speech sessions and command runners;
- preference defaults and round trips in an isolated defaults suite.

Manual acceptance after packaging:

1. Launching the app produces only a menu-bar item.
2. The app requests microphone and speech permissions with clear descriptions.
3. Saying `computer` followed by words invokes `/usr/bin/open` with one encoded
   URL argument.
4. Holding the configured shortcut, speaking, and releasing invokes the same
   command without a wake phrase.
5. Disabling passive listening releases the microphone.
6. A malformed executable produces a visible error and never invokes a shell.

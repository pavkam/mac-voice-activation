# Voice Activation

A small macOS menu-bar app that listens for a wake phrase or a push-to-talk
shortcut, transcribes the speech, and invokes one configured executable.

It is intentionally focused: native speech recognition, a configurable command,
push-to-talk, and a menu-bar lifecycle with no server or account dependency.

## Requirements

- macOS 15 or later
- Swift 6.2 or later
- Xcode Command Line Tools or Xcode

## Build and run

```bash
cd ~/Development/voice-activation
make test
make run
```

The app bundle is created at `.build/VoiceActivation.app`. It runs only in the
menu bar and requests Microphone and Speech Recognition access when voice input
is first enabled.

An ad-hoc signature is used by default. macOS privacy grants may need to be
given again after rebuilding an ad-hoc-signed bundle. To use an installed
signing identity:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make app
```

## Use

- Passive wake is on by default. Grant the requested permissions and the app
  listens for **“computer”** immediately; the menu toggle disables it.
- Say `computer`, then the command text. The command is submitted after speech
  recognition finalizes or the transcript remains unchanged for 1.5 seconds.
- While recording, a compact animated microphone floats above the current app,
  expands to show live transcription, and offers a cancel button.
- Say only `cancel`, `stop`, or `dismiss` to discard the capture. Repeating the
  same word twice cancels immediately, even before recognition finalizes.
- Hold the push-to-talk shortcut shown in the menu, speak without a wake phrase,
  then release. Change it by clicking the shortcut in Settings and pressing a
  new modifier-plus-key combination.
- Open **Settings…** from the menu to change the wake phrase, locale,
  push-to-talk shortcut, executable, argument templates, and whether the app
  launches at login.

Passive listening requires on-device recognition for the selected locale and
fails closed if the Mac does not support it. Push-to-talk may use Apple's speech
service when on-device recognition is unavailable.

## Command templates

The default opens a Google search:

```text
Executable: /usr/bin/open
Argument:   https://www.google.com/search?q={urlText}
```

Each non-empty line in the Arguments editor becomes one process argument.

- `{text}` inserts the transcription literally into that argument.
- `{urlText}` inserts an RFC 3986 percent-encoded query value.

For a custom URL scheme:

```text
Executable: /usr/bin/open
Argument:   my-app://command?prompt={urlText}
```

The app launches the executable directly with `Process`. It never invokes a
shell, so punctuation in speech cannot become shell syntax.

## Development

```bash
make build
make test
make app
```

## Documentation

See the [documentation index](docs/index.md) for installation, configuration,
architecture, troubleshooting, and development guides.

# Voice Activation

A small macOS menu-bar app that listens for configurable wake phrases or a
push-to-talk shortcut, transcribes speech, and opens the URL assigned to the
matched phrase.

It is intentionally focused: native speech recognition, colored wake profiles,
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
  listens for **“computer”** immediately. Each saved wake phrase has its own
  menu toggle, so phrases can be enabled or disabled independently.
- Say `computer`, then the command text. The command is submitted after speech
  recognition finalizes or the transcript remains unchanged for 1.5 seconds.
- Add as many wake profiles as needed. Each phrase has its own URL template and
  accent color; the matched color carries through the recording animation.
  Newly added phrases are enabled by default.
- While recording, a compact animated microphone floats above the current app,
  expands to show live transcription, offers a cancel button, and plays distinct
  sounds when capture starts and ends.
- Say only `cancel`, `stop`, or `dismiss` to discard the capture. Repeating the
  same word twice cancels immediately, even before recognition finalizes.
- Give any wake profile its own push-to-talk shortcut. Hold that shortcut, speak
  without the wake phrase, then release; the profile’s URL and color are used.
  Each assigned binding appears beside its phrase in the menu.
- Open **Settings…** from the menu to add or remove wake profiles, change their
  URLs, colors, and shortcuts, set the locale, or enable launch at login.

Passive listening requires on-device recognition for the selected locale and
fails closed if the Mac does not support it. Push-to-talk may use Apple's speech
service when on-device recognition is unavailable.

## Wake profiles

The default opens a Google search:

```text
Wake phrase: computer
URL:         https://www.google.com/search?q={urlText}
Color:       Blue
```

- `{text}` inserts the transcription literally into that argument.
- `{urlText}` inserts an RFC 3986 percent-encoded query value.

For a custom URL scheme:

```text
Wake phrase: ask assistant
URL:         my-app://command?prompt={urlText}
Color:       Purple
```

The app opens profile URLs directly with `/usr/bin/open`. It never invokes a
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

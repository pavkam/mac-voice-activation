# Voice Activation

A small macOS menu-bar app that listens for configurable wake phrases or a
push-to-talk shortcut, transcribes speech, and either runs a direct command or
sends the request to a local coding agent through Agent Client Protocol (ACP).

It is intentionally focused: native speech recognition, colored wake profiles,
push-to-talk, direct argument execution, and streamed local-agent runs without
a Voice Activation server or account.

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
  row in the polished menu-bar control panel, so phrases can be enabled or
  disabled independently while their push-to-talk shortcuts remain visible.
  **Pause all** stops every passive wake listener without changing those
  individual choices; **Resume all** restores them.
- Say `computer`, then the command text. The command is submitted after speech
  recognition finalizes or the transcript remains unchanged for 1.5 seconds.
- Add as many wake profiles as needed. Each phrase has its own command or agent
  target and accent color; the matched color carries through capture and agent
  execution. Newly added phrases are enabled by default.
- While recording, a compact animated microphone floats above the current app,
  expands to show a rolling tail of the live transcription, offers a cancel
  button, and plays distinct sounds when capture starts and ends.
- Say only `cancel`, `stop`, or `dismiss` to discard the capture. Repeating the
  same word twice cancels immediately, even before recognition finalizes.
  Numbers remain command content, so phrases such as `stop 123` are submitted
  normally instead of being mistaken for cancellation.
- Give any wake profile its own push-to-talk shortcut. Hold that shortcut, speak
  without the wake phrase, then release; the profile’s target and color are used.
  Each assigned binding appears beside its phrase in the menu.
- Open **Settings…** from the menu to add or remove wake profiles, choose their
  command or agent targets, change colors and shortcuts, set the locale, or
  enable launch at login.

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

## Local coding agents

Set a profile's **Target** to **Agent**, then choose Cursor, Codex, Claude, or a
custom ACP v1 executable. A fresh Agent target selects the first installed
provider it can find. The executable field resolves command names from the
app's inherited `PATH` and common Homebrew, local, ChatGPT, and NVM locations;
**Detect** retries discovery, while the folder button selects an executable
directly. Select an absolute working folder, choose a permission policy, and
save.

The app keeps the foreground application focused while a floating panel streams
an ordered Markdown timeline. Tool work starts as a compact animated row and
collapses to an expandable result row when it finishes—even when a provider
omits a final tool status; permission prompts disappear as soon as a choice is
made. New output follows the bottom of the panel until you deliberately scroll
upward.

The microphone stays live after the first response. Speak another request—or
use the profile's push-to-talk binding—to continue in the same ACP session and
timeline. **Stop turn** cancels only the current work; **End conversation**
returns to passive wake listening. Saying only `cancel`, `stop`, or `dismiss`
always ends the whole conversation and returns to passive wake listening.
Up to 16 follow-ups may wait behind active work; the panel reports when that
bounded queue is full instead of growing memory without limit.

Settings can read completed replies aloud with the matching macOS system voice
and play a quiet repeating pulse through long thinking/tool pauses. Both options
are enabled by default. Voice cancellation says “Stopped” when reply speech is
enabled, and tests inject silent audio players, so CI never emits speaker sounds.
Completed output remains selectable and copyable until the panel is closed.
Copied output contains the request, response Markdown, and bounded diagnostics.
Its response section separates conversation turns and excludes provider thought
updates.

Provider authentication stays with the provider CLI. Voice Activation stores
no API keys, prompt history, agent output, or raw tool payloads. See the
[ACP agent harness guide](docs/agent-harness.md) for configuration, safety
bounds, lifecycle details, and supported protocol behavior.

## Development

```bash
make build
make test
make app
```

## Documentation

See the [documentation index](docs/index.md) for installation, configuration,
architecture, troubleshooting, and development guides.

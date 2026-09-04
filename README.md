<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Voice Activation

A native macOS menu-bar voice launcher for configurable wake phrases,
push-to-talk commands, and live conversations with local coding agents through
Agent Client Protocol (ACP). It transcribes speech, runs direct commands, streams
Markdown agent output, and keeps the conversation controllable by voice.

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
directly. Select an absolute working folder, choose a default permission policy,
add an optional profile-specific system prompt, and save.

The app keeps the foreground application focused while a floating panel streams
an ordered Markdown timeline. Tool work starts as a compact animated row and
collapses to an expandable result row when it finishes—even when a provider
omits a final tool status; permission prompts disappear as soon as a choice is
made. Say `allow`, `allow all`, `deny`, or `deny all` to answer the oldest
visible permission request without touching the panel. New output follows the
bottom of the panel until you deliberately scroll upward. Drag the panel by its
header to move it out of the way, or minimize it into a movable live-status pill
that stays above other windows and restores the full conversation with one click.

The microphone stays live after the first response. Speak another request—or
use the profile's push-to-talk binding—to continue in the same ACP session and
timeline. **Stop turn** cancels only the current work; **End conversation**
returns to passive wake listening. Saying only `cancel`, `stop`, or `dismiss`
always ends the whole conversation and returns to passive wake listening.
Up to 16 follow-ups may wait behind active work; the panel reports when that
bounded queue is full instead of growing memory without limit.

Each profile keeps its own ACP session. The app retains at most four live
profile sessions, evicts the least recently used idle one, and recovers once
when a provider forgets a cached session before any agent work begins. Recovery
and cache-eviction context resets are visible in the conversation; prompts are
never replayed after output or a permission request.

Settings can read replies aloud as they stream, using either the matching macOS
system voice or an ElevenLabs voice loaded from the account catalog. The
selected voice can be previewed before saving, with manual Voice ID entry as a
fallback when the catalog is unavailable. Complete sentences are queued
immediately; unfinished text is queued within 350 milliseconds even while more
tokens keep streaming. ElevenLabs prefetches upcoming speech while preserving
playback order. The thinking pulse continues during cloud synthesis and pauses
only while speech plays. A bundled sound palette distinguishes listening,
thinking, and tool transitions without making runtime effect-generation calls.
Voice cancellation says “Stopped” when
reply speech is enabled, and tests inject silent audio players, so CI never emits
speaker sounds.
Closing the completed panel keeps its bounded output available from **Open** in
the menu. **Delete** is available both there and in the conversation panel; it
hides the panel and releases that retained output from memory.
Copied output contains the request, response Markdown, and bounded diagnostics.
Its response section separates conversation turns and excludes provider thought
updates.

Agent authentication stays with the provider CLI. The optional ElevenLabs API
key is stored in macOS Keychain rather than source code or preferences. Voice
Activation stores no prompt history, agent output, or raw tool payloads. See the
[ACP agent harness guide](docs/agent-harness.md) for configuration, safety
bounds, lifecycle details, and supported protocol behavior.
The [sound-design guide](docs/sound-design.md) documents every cue and its
playback contract.

## Development

```bash
make build
make test
make app
make check-license
```

## Documentation

See the [documentation index](docs/index.md) for installation, configuration,
architecture, troubleshooting, and development guides.

## License

Voice Activation is available under the [MIT License](LICENSE).
Copyright © 2026 Alexandru Ciobanu
([alex+git@ciobanu.org](mailto:alex+git@ciobanu.org)).

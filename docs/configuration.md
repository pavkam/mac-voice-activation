# Configuration

Open the menu-bar item and choose **Settings…**. Wake-profile, locale, and
push-to-talk changes take effect after you select **Save Settings**. Startup
changes apply immediately. A successful save closes the Settings window;
validation errors keep it open so the invalid field can be corrected.

## Voice settings

- **Wake profiles:** each profile has a wake phrase, run target, and presentation
  color. Add or remove profiles as needed. Phrases must be unique after the same
  case, width, accent, punctuation, and symbol normalization used by matching,
  and occur at the beginning of the recognized utterance. If phrases overlap,
  the longest match wins. The menu-bar menu has a separate persistent toggle
  for every saved phrase. Disabled phrases are excluded from recognition
  without affecting the other profiles. Use **Pause all** in the same menu to
  stop passive recognition without changing those per-profile choices; use
  **Resume all** to restore listening for the previously enabled phrases.
- **Speech locale:** defaults to the current macOS locale and accepts an Apple
  locale identifier such as `en-US` or `pt-PT`.
- **Always listen:** enabled by default and keeps an on-device recognition
  session active for every enabled wake phrase.
- **Push to talk:** each wake profile may have its own shortcut. Holding a
  profile’s binding captures speech without requiring its wake phrase, then runs
  that profile’s target and uses its presentation color. Click **Set shortcut**,
  then press a combination containing Control, Option, Shift, or Command plus
  another key.
  Press Escape to cancel recording, or select **Save Settings** to apply every
  recorded binding. Assigned bindings must be unique. If another application owns
  a combination, Voice Activation restores the previous saved bindings and reports
  the conflict.

A wake phrase must be enabled and end at a word boundary. `computer, open calendar`
matches; `supercomputer open calendar` does not. A profile’s push-to-talk binding
remains available when that profile’s passive wake phrase or all passive listening
is disabled.

Passive recognition fails closed when the selected locale does not support
on-device recognition. Command capture and push-to-talk may use Apple's speech
service when on-device recognition is unavailable.

## Startup

Enable **Launch at Login** to register the current app bundle as a macOS login
item. The change applies immediately and does not depend on **Save Settings**.

macOS remains the source of truth for this option. You can also inspect or
change it under **System Settings › General › Login Items**. Install a stable,
signed copy of Voice Activation in `/Applications` before enabling it; a login
item that points into `.build` will stop working when that bundle is replaced
or removed.

## Run targets

Each profile independently selects one target:

- **Command** launches an absolute executable with explicit argument templates.
- **Agent** starts an ACP v1 provider process, sends the transcript as a prompt,
  and streams its observable output into the floating agent panel.

### Command targets

Every command target must contain a transcript placeholder in at least one
argument. The default target opens the resulting URL with `/usr/bin/open`.

| Placeholder | Expansion |
| --- | --- |
| `{text}` | Inserts the transcript literally into the argument. |
| `{urlText}` | Inserts an RFC 3986 percent-encoded query value. |

Voice Activation starts `/usr/bin/open` directly with `Process`. It never sends
the command through a shell.

### Open a search URL

```text
Wake phrase: search
URL:
https://www.google.com/search?q={urlText}
```

### Open a custom URL scheme

```text
Wake phrase: ask assistant
URL:
my-app://command?prompt={urlText}
```

### Agent targets

Choose one of the provider presets or **Custom**. A preset fills editable
defaults; a fresh Agent target selects the first available preset automatically.
Use **Detect** to resolve a command name from the app's inherited `PATH` and
known install locations, or use the file button to choose it directly. The saved
absolute executable and argument list remain authoritative. Finder-launched apps
do not inherit an interactive shell's complete `PATH`, so the detector also
checks common Homebrew, local, ChatGPT, and NVM locations.

| Field | Meaning |
| --- | --- |
| Provider | Cursor, Codex, Claude, or Custom ACP v1 process. |
| Display name | Label shown in the menu and floating run panel. |
| Executable | Detected command or absolute ACP process path. |
| Working folder | Absolute project directory supplied to `session/new`. |
| Permission policy | Ask in the panel, automatically allow once, or reject. |
| Adapter arguments | Direct process arguments; no shell parsing occurs. |

The Cursor preset uses `cursor-agent acp`. Codex and Claude use pinned ACP
adapter package versions through `npx`. Authenticate with the corresponding
provider CLI before triggering the profile. Voice Activation inherits the
launch environment but never persists API keys.

See [ACP agent harness](agent-harness.md) for streaming, cancellation,
permissions, safety bounds, and provider lifecycle behavior.

## Capture timing

- A compact recording orb appears near the bottom center of the active screen
  while command capture or push-to-talk is active. It expands into a
  translucent live-transcript capsule with a continuous morph after words
  arrive. Long transcripts rotate out their oldest words so the newest speech
  remains visible. The overlay never takes keyboard focus from the current app.
  The capsule is clipped to its visible border without an outer shadow gutter.
  Click its close button to discard the current capture.
- The orb and capsule use the matched profile's accent color. Distinct sounds
  play once when capture starts and once when it leaves capture for any reason.
- A wake phrase recognized by itself starts a fresh command-capture session,
  allowing a natural pause before the command. A brief grace period preserves
  command words spoken in the same utterance; otherwise the dedicated listener
  starts well before Apple's wake utterance would time out and remains available
  throughout the five-second initial-silence window.
- A completed command consisting only of `cancel`, `stop`, or `dismiss`
  discards the capture. Repeating the same cancellation word twice in a row
  discards it immediately, including while recognition is still partial. A
  longer command such as `stop the music` runs normally.
- After command text arrives, 1.5 seconds without a transcript change submits
  the best transcription.
- Capture without any command text returns to passive listening after 5
  seconds. Active dictation has a 30-second absolute maximum.
- Successful commands return to passive listening after a 250-millisecond
  cooldown.
- Disabling every wake profile stops passive microphone capture even when the
  global **Always listen** preference remains enabled. Enabling any profile
  starts passive capture again. Profile push-to-talk shortcuts remain available.

Next: [understand the runtime architecture](architecture.md).

# Configuration

Open the menu-bar item and choose **Settings…**. Wake-profile, locale, and
push-to-talk changes take effect after you select **Save Settings**. Startup
changes apply immediately. A successful save closes the Settings window;
validation errors keep it open so the invalid field can be corrected.

## Voice settings

- **Wake profiles:** each profile has a wake phrase, URL template, and animation
  color. Add or remove profiles as needed. Phrases must be unique and occur at
  the beginning of the recognized utterance. Matching ignores case, accents,
  and character width; if phrases overlap, the longest match wins. The menu-bar
  menu has a separate persistent toggle for every saved phrase. Disabled phrases
  are excluded from recognition without affecting the other profiles.
- **Speech locale:** defaults to the current macOS locale and accepts an Apple
  locale identifier such as `en-US` or `pt-PT`.
- **Always listen:** enabled by default and keeps an on-device recognition
  session active for every enabled wake phrase.
- **Push to talk:** defaults to Control-Option-Space and does not require the
  wake phrase. Click the shortcut button, then press a new combination containing
  Control, Option, Shift, or Command plus another key. Press Escape to cancel
  recording, or select **Save Settings** to apply the recorded combination. Until
  then, the menu and global hotkey continue using the saved shortcut. If another
  application owns the combination, Voice Activation keeps the previous shortcut
  and reports the conflict.

A wake phrase must be enabled and end at a word boundary. `computer, open calendar` matches;
`supercomputer open calendar` does not. Push-to-talk uses the first saved wake
profile's URL and color because no spoken wake phrase selects one. It prefers
the first enabled profile but remains available when every phrase is disabled.

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

## Profile URLs

Every profile URL must contain a transcript placeholder. Voice Activation opens
the resulting URL with `/usr/bin/open`.

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

## Capture timing

- A compact recording orb appears near the bottom center of the active screen
  while command capture or push-to-talk is active. It expands into a
  translucent live-transcript capsule with a continuous morph after words
  arrive and never takes keyboard focus from the current app. The capsule is
  clipped to its visible border without an outer shadow gutter. Click its close
  button to discard the current capture.
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

Next: [understand the runtime architecture](architecture.md).

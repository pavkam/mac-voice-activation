# Configuration

Open the menu-bar item and choose **Settings…**. Changes take effect after you
select **Save Settings**.

## Voice settings

- **Wake phrase:** defaults to `computer` and must occur at the beginning of
  the recognized utterance. Matching ignores case, accents, and character
  width.
- **Speech locale:** defaults to the current macOS locale and accepts an Apple
  locale identifier such as `en-US` or `pt-PT`.
- **Always listen:** enabled by default and keeps an on-device recognition
  session active for the wake phrase.
- **Push to talk:** Control-Option-Space is a fixed global shortcut and does not
  require the wake phrase.

The wake phrase must end at a word boundary. `computer, open calendar` matches;
`supercomputer open calendar` does not.

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

## Command settings

The executable must be an absolute path to a runnable file. Each non-empty line
in **Arguments** becomes one process argument, in order. At least one argument
must contain a transcript placeholder.

| Placeholder | Expansion |
| --- | --- |
| `{text}` | Inserts the transcript literally into the argument. |
| `{urlText}` | Inserts an RFC 3986 percent-encoded query value. |

Voice Activation starts the executable directly with `Process`. It never sends
the command through `sh`, `zsh`, or another shell, so shell operators inside a
transcript remain ordinary argument text.

### Open a search URL

```text
Executable: /usr/bin/open
Arguments:
https://www.google.com/search?q={urlText}
```

### Open a custom URL scheme

```text
Executable: /usr/bin/open
Arguments:
my-app://command?prompt={urlText}
```

### Pass text to a macOS Shortcut

Create a Shortcut that accepts text input, then configure one argument per
line:

```text
Executable: /usr/bin/shortcuts
Arguments:
run
My Voice Shortcut
-i
{text}
```

## Capture timing

- A wake phrase that finalizes by itself starts a fresh command-capture session,
  allowing a natural pause before the command.
- After command text arrives, 1.5 seconds without a transcript change submits
  the best transcription.
- Capture without a command returns to passive listening after 30 seconds.
- Successful commands return to passive listening after a 250-millisecond
  cooldown.

Next: [understand the runtime architecture](architecture.md).

# Voice Activation documentation

Voice Activation is a native macOS menu-bar app that listens for a wake phrase
or a push-to-talk shortcut, transcribes a command, and invokes a configured
executable without passing speech through a shell.

## Guides

| Guide | Use it to |
| --- | --- |
| [Getting started](getting-started.md) | Build, launch, grant permissions, and run the first command. |
| [Configuration](configuration.md) | Set the wake phrase, locale, executable, and argument templates. |
| [Architecture](architecture.md) | Understand speech modes, state transitions, privacy, and process execution. |
| [Troubleshooting](troubleshooting.md) | Diagnose permissions, recognition, shortcuts, and command failures. |
| [Development](development.md) | Work with the package, tests, app bundle, and continuous integration. |

## Core behavior

- Passive listening is enabled by default and uses on-device recognition.
- The default wake phrase is `computer`.
- Control-Option-Space provides push-to-talk without a wake phrase.
- An animated translucent overlay shows recording state and partial words.
- Launch at Login registers the app through macOS Service Management.
- Spoken text is inserted into explicit process arguments through `{text}` or
  `{urlText}` placeholders.
- The app has no Dock icon, server, account, audio archive, or shell-evaluation
  layer.

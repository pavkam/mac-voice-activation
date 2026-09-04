<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Voice Activation documentation

Voice Activation is a native macOS menu-bar app that listens for configurable
wake phrases or a push-to-talk shortcut, transcribes a request, and routes it
to either a direct command or a local ACP coding agent without passing speech
through a shell.

## Guides

| Guide | Use it to |
| --- | --- |
| [Getting started](getting-started.md) | Build, launch, grant permissions, and run the first command. |
| [Configuration](configuration.md) | Configure wake phrases, command or agent targets, colors, locale, and push-to-talk. |
| [ACP agent harness](agent-harness.md) | Configure Cursor, Codex, Claude, or a custom ACP v1 agent and understand streamed runs. |
| [Sound design](sound-design.md) | Understand listening, thinking, and tool-transition cues. |
| [Architecture](architecture.md) | Understand speech modes, state transitions, privacy, and process execution. |
| [Troubleshooting](troubleshooting.md) | Diagnose permissions, recognition, shortcuts, commands, and agent runs. |
| [Development](development.md) | Work with the package, tests, app bundle, and continuous integration. |

## Core behavior

- Passive listening is enabled by default and uses on-device recognition.
- The default wake profile is `computer`, a Google search URL, and blue.
- Multiple wake profiles can route speech to different commands or ACP agents
  and presentation colors.
- Every wake profile can have a distinct push-to-talk shortcut that uses that
  profile’s URL and color.
- An animated translucent overlay and start/end sounds show capture state.
- Launch at Login registers the app through macOS Service Management.
- Command targets insert spoken text into explicit process arguments through
  `{text}` or `{urlText}` placeholders. Agent targets send it as an ACP text
  content block.
- Agent targets stream bounded Markdown into a non-activating floating panel.
  Reasoning and tools collect in one expandable **Thinking** card per work
  burst, then the microphone stays live for spoken follow-ups.
- Each agent profile can provide its own system prompt and default permission
  level; interactive permission requests can be answered by voice.
- Streaming reply speech through macOS or ElevenLabs and narration-aware
  activity sounds make agent conversations audible. Dedicated cues distinguish
  thinking, tool start, tool completion, and tool failure. ElevenLabs voices are
  loaded from the account catalog and can be previewed; tests always replace
  network and playback boundaries with silent adapters.
- The app has no Dock icon, server, Voice Activation account, audio archive,
  run-history database, or shell-evaluation layer.

<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Project architecture

## Product shape

Voice Activation is a SwiftPM macOS 15 menu-bar app built with Swift tools 6.2.
It listens for configurable wake phrases or per-profile push-to-talk shortcuts,
transcribes speech, then either launches a direct command or streams a prompt to
a local ACP v1 agent.

There is no server or Voice Activation account. A SwiftUI `MenuBarExtra` owns
the controls. AppKit hosts non-activating recording and agent panels so the
foreground application keeps keyboard focus.

## Module ownership

```text
Sources/VoiceActivationCore/       Framework-independent behavior
Sources/VoiceActivationApp/        macOS adapters, composition, and UI
Tests/VoiceActivationCoreTests/    Core contracts
Tests/VoiceActivationAppTests/     App and adapter contracts
```

### VoiceActivationCore

- `VoiceActivationCoordinator`: main-actor state machine for listening,
  capture, commands, and conversations.
- Wake-profile types: matching, validation, action, and hotkey identity.
- `CommandTemplate`/`CommandRunner`: validated argument expansion and direct
  process execution.
- `ACPAgentRunner`, `ACPClientConnection`, `ACPProcessTransport`: cached ACP
  sessions, JSON-RPC turns, permissions, processes, and pipes.
- `AgentRunEventDelivery`: ordered bounded transport-to-consumer delivery.
- `MainRunLoopScheduler`: ordered delivery in default, common, modal-panel, and
  event-tracking run-loop modes.
- `AppPreferences`: non-secret persisted configuration.

Core contains pure transitions, validation, framing, bounds, and
process-independent policy. It must not import SwiftUI or AppKit.

### VoiceActivationApp

- `VoiceActivationApp` composes dependencies; `AppModel` bridges UI and Core.
- Apple Speech, microphone permissions, audio-engine recovery, and capture.
- SwiftUI menu/Settings plus AppKit panel presenters/controllers.
- Carbon shortcuts and Service Management launch-at-login.
- Reply narration, activity sounds, ElevenLabs adapters, and Keychain storage.
- Privacy-safe rotating JSONL diagnostics.

Keep framework types behind narrow protocols when tests need replacement. Do
not add a manager or view model that merely forwards one concrete operation.

## Runtime paths

```text
permission -> passive speech -> wake/push-to-talk -> capture
  -> command: validated argv -> direct Process -> passive speech
  -> agent: ACP runner -> ordered events -> presentation/panel
            -> conversation speech -> follow-up or explicit end
```

Push-to-talk pins its profile before asynchronous permission work. During an
active conversation it becomes a follow-up rather than a new profile run.

## Where new behavior belongs

| Behavior | Owner |
| --- | --- |
| Pure state, matching, validation, bounds | Core |
| JSON-RPC/session/process policy | Core ACP types |
| Semantic mapping for display | App presentation types |
| macOS framework calls/window lifecycle | App adapters/controllers |
| Layout calculations | Pure App helpers |
| View rendering | SwiftUI |
| Dependency construction | App composition root |

For the full current model, read `docs/architecture.md`. For ACP wire details,
use `acp-integration`; for panel/presentation boundaries, use
`ux`; for spoken replies, use `voice-reading`.

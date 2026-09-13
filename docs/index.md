<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# YapOps documentation

Use this index to move from first launch to the guide that owns a setting,
runtime contract, investigation, or contributor workflow.

## Start here

| Guide | Use it to |
| --- | --- |
| [Getting started](getting-started.md) | Build, launch, grant permissions, and run the first command. |
| [Configuration reference](configuration.md) | Check saved defaults, field meanings, validation, and persistence. |
| [Troubleshooting](troubleshooting.md) | Recover from common permission, recognition, command, agent, audio, and login-item symptoms. |

## Use YapOps

| Guide | Use it to |
| --- | --- |
| [Wake profiles](wake-profiles.md) | Configure wake matching, passive listening, push-to-talk, capture timing, and voice cancellation. |
| [Command targets](command-targets.md) | Pass recognized text to a direct executable without shell evaluation. |
| [Agent providers](agent-providers.md) | Configure, discover, authenticate, and constrain an ACP provider. |
| [Agent conversations](agent-conversations.md) | Use the panel, follow-ups, permissions, narration, cancellation, and retained output. |
| [Sound design](sound-design.md) | Understand capture, thinking, and tool cues and when they play. |

## Understand the system

| Guide | Use it to |
| --- | --- |
| [Architecture](architecture.md) | Locate package, subsystem, state-flow, and adapter ownership. |
| [Design system](design-system.md) | Find the token a surface should use, and what the design system describes but YapOps does not build. |
| [ACP agent harness](agent-harness.md) | Read the process, wire, session, permission, cancellation, recovery, and delivery contract. |
| [Concurrency and lifecycle](concurrency-and-lifecycle.md) | Trace actor isolation, identities, callbacks, queues, cancellation order, and shutdown. |
| [Privacy and security](privacy-and-security.md) | Understand data paths, trust boundaries, credentials, persistence, redaction, and retention. |
| [Diagnostics](diagnostics.md) | Inspect and safely share the structured runtime trace. |

## Contribute

| Guide | Use it to |
| --- | --- |
| [Development](development.md) | Set up the toolchain, navigate the repository, and make a focused change. |
| [Testing](testing.md) | Place tests, run focused suites, choose proportional gates, and report evidence. |
| [Packaging](packaging.md) | Build, sign, verify, install, and provision the application bundle. |
| [Documentation](documentation.md) | Choose the owning guide and review documentation against live evidence. |

## Terminology

- A **profile** combines one wake phrase, one target — a command, a set of macOS
  system actions, or an agent — an accent, an enabled state, and an optional
  push-to-talk shortcut.
- A **system action** is a macOS operation such as play/pause or lock screen,
  invoked by speaking a bound term after the profile's wake phrase.
- **Passive wake** is continuous on-device recognition used only to detect the
  enabled profiles' wake phrases.
- A **capture** is one recognized utterance being collected for a profile or an
  active agent conversation.
- A **conversation** is one retained agent session and its visible timeline. It
  may contain several turns.
- A **turn** is one user request and the corresponding agent work inside a
  conversation.

## Related guides

- [Project README](../README.md)

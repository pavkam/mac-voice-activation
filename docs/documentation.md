<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Documentation

Use this guide when adding or updating repository documentation. It defines the
owner for each kind of claim, the terms shared across guides, and the evidence a
documentation change needs before it is complete.

## Choose the owning guide

Put a detailed contract in one guide. Other pages may summarize it for their
audience, but they should link to the owner instead of maintaining a second copy.

| Guide | Owns |
| --- | --- |
| `README.md` | Product overview, requirements, minimal quick start, capability and safety summaries. |
| `docs/index.md` | Task-based navigation and shared terminology. |
| `docs/getting-started.md` | First build, permissions, first command, and stable local installation. |
| `docs/configuration.md` | Saved settings, defaults, validation, and when changes take effect. |
| `docs/wake-profiles.md` | Wake matching, enablement, push-to-talk, capture timing, and spoken cancellation. |
| `docs/command-targets.md` | Direct executables, argument expansion, examples, validation, and shell safety. |
| `docs/agent-providers.md` | Provider presets, discovery, authentication, working folders, prompts, and permission defaults. |
| `docs/agent-conversations.md` | Panel behavior, follow-ups, permissions, narration, cancellation, and retained output. |
| `docs/sound-design.md` | Cue timing, playback conditions, assets, and silent-test behavior. |
| `docs/troubleshooting.md` | Symptom-oriented recovery steps. |
| `docs/architecture.md` | Package and subsystem ownership plus top-level state flow. |
| `docs/design-system.md` | Design token ownership, the profile accent, copy voice, and design-system adoption boundaries. |
| `docs/agent-harness.md` | ACP process, wire, session, prompt, permission, cancellation, recovery, and delivery contracts. |
| `docs/concurrency-and-lifecycle.md` | Isolation, identities, callbacks, queues, run-loop delivery, and shutdown. |
| `docs/privacy-and-security.md` | Data paths, credentials, persistence, redaction, and resource bounds. |
| `docs/diagnostics.md` | Runtime trace schema, rotation, commands, timing, and investigations. |
| `docs/development.md` | Repository layout, prerequisites, commands, source conventions, and change workflow. |
| `docs/testing.md` | Test architecture, focused iteration, verification, sanitizers, and CI. |
| `docs/packaging.md` | Bundle assembly, resources, signing, verification, installation, and Launch at Login. |
| `docs/documentation.md` | Documentation ownership, terminology, style, evidence, and review. |

When a change crosses owners, update each affected guide but keep shared details
in the narrowest canonical page. For example, the README can say direct commands
never use a shell; `command-targets.md` owns how executable paths and arguments
are validated and launched.

## Shared terminology

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

Use **menu bar**, **push-to-talk**, **Launch at Login**, **Settings**, **Stop
turn**, and **End conversation** consistently. Use ACP for Agent Client Protocol
after spelling it out on first use in a standalone guide.

## Write from evidence

Production code and tests override prose. Before changing a behavioral claim:

1. Locate its production owner with `rg`.
2. Read the complete state, validation, or lifecycle path involved.
3. Confirm high-impact security and lifecycle behavior in a focused test or
   build contract.
4. Record exact numbers only in the owning guide.
5. Check every summary for contradictions after the owner changes.

Use these evidence pairs for common areas:

| Claim | Production owner | Independent evidence |
| --- | --- | --- |
| Defaults and persistence | `AppPreferences`, `WakeProfile` | preferences and draft tests |
| Wake matching and capture | coordinator speech extensions, matcher, timing | coordinator capture tests |
| Direct commands | `CommandTemplate`, `CommandRunner` | command tests |
| Provider setup | harness configuration, executable locator | draft and locator tests |
| ACP lifecycle and limits | runner, connection, delivery, transport | focused ACP suites |
| Panel and conversation behavior | presentation, panel, app model | presentation and conversation tests |
| Narration and sounds | audio orchestrator, segmenter, speech queue | audio and sound tests |
| Diagnostics and privacy | diagnostic recorder and call sites | redaction, credential, and bounds tests |
| Build and packaging | `Makefile`, build script, resources | CI and bundle verification |

Do not document an external provider's behavior as a YapOps guarantee
unless the repository probes or tests that behavior.

## Update documentation with behavior

Update the owning guide in the same change when behavior, defaults, validation,
configuration, privacy, diagnostics, packaging, or developer commands change.
New subsystems need an architecture owner and a route from `docs/index.md`.

Delete obsolete prose instead of appending release history. If a familiar guide
is split, keep the familiar path useful and link it to the new focused owner.

## Style and structure

- Start with what the guide helps the reader accomplish and when to use it.
- Use second person for tasks and precise present tense for reference material.
- Prefer task-oriented headings in user guides and contract-oriented headings
  in architecture or protocol references.
- Keep examples executable or directly transferable to Settings.
- Use tables for comparable fields, defaults, limits, or commands.
- Avoid promotional adjectives, hidden prerequisites, implementation trivia in
  user workflows, and duplicated numeric contracts.
- End focused guides with **Related guides** instead of a forced reading order.

## Headers and links

Every Markdown file needs the MIT SPDX header within its first 12 lines. Use
relative links between repository guides and descriptive link text. Link to a
specific owner rather than the documentation index when the destination is
known.

Before committing, resolve every changed local link and check that new guides
are reachable from `docs/index.md`. Links from approved design and plan records
under `docs/superpowers/` are historical artifacts; do not rewrite them during a
presentation-only cleanup.

## Review checklist

- The content has one clear audience and responsibility.
- Every behavioral claim agrees with its production owner.
- Security or lifecycle claims have independent evidence.
- Defaults and limits appear in their canonical guide.
- Related summaries link to the owner instead of copying it.
- Terms, headings, examples, and UI labels are consistent.
- Local links resolve and the guide is reachable from the index.
- `make check` and `git diff --check` pass.

## Related guides

- [Documentation index](index.md)
- [Architecture](architecture.md)
- [Development](development.md)
- [Testing](testing.md)

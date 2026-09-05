---
name: development
description: Use when changing or reviewing production code, architecture, dependencies, repository structure, developer guidance, command execution, lifecycle, or Swift concurrency.
---

<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Development

Keep the native macOS app small, deterministic, private, and easy to diagnose.
Live code and tests beat prose when they disagree; update stale guidance with
the behavior change.

## Load only what the task needs

| When the task touches | Read |
| --- | --- |
| Module ownership, runtime flow, a new type, or moving behavior | `references/project-architecture.md` |
| Swift APIs, actor isolation, tasks, callbacks, continuations, or public Core symbols | `references/swift-engineering.md` |
| Processes, credentials, untrusted data, privacy, cancellation, queues, or lifecycle | `references/security-and-lifecycle.md` |
| Dependencies, files, docs, build commands, or pre-edit checks | `references/repository-workflow.md` |
| `AGENTS.md`, a project skill, reference, or instruction-discovery rule | `references/agent-guidance.md` |

Do not load every reference defensively. Start with the row matching the change,
then follow links only when the work crosses another boundary.

## Working contract

1. Inspect `git status --short`, the relevant diff, production owner, and nearby
   tests. Preserve unrelated user work.
2. State the observable behavior and the invariant at risk.
3. Put pure policy in Core and macOS framework adapters in App. Add an
   abstraction only when it owns a real replacement, invariant, or lifecycle.
4. Add the smallest deterministic failing test before behavior code, then make
   one coherent implementation change.
5. Load the testing skill and run verification proportional to the changed
   boundary.

## Project invariants

- Direct commands use `Foundation.Process` with explicit arguments, never a
  shell. Provider authentication remains with provider CLIs.
- Passive recognition stays on-device. Secrets stay in Keychain; sensitive
  content and audio never enter diagnostics.
- Main-actor state, generation/run/session identity, cancellation authority,
  bounds, ordering, and backpressure must survive asynchronous work.
- Blocking foreign APIs stay off the main actor and Swift cooperative executor.
- Menu and floating panels remain non-activating and preserve foreground focus.

**REQUIRED SUB-SKILL:** Use `testing-and-debugging` for tests,
diagnosis, profiling, or completion verification. Also use `acp-integration`,
`ux`, or `voice-reading` when that domain is affected.

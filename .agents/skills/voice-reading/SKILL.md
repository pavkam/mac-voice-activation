---
name: voice-reading
description: Use when changing, reviewing, debugging, or testing spoken agent replies in Voice Activation, including narration segmentation, macOS speech, ElevenLabs TTS, voice catalogs, credentials, playback, fallbacks, interruption, activity sounds, or speech settings.
---

<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Voice Reading

Treat spoken output as a cancellable, ordered projection of the visible agent
reply—not as a second transcript. The fastest voice is useless if it reads code,
talks over the user, or loses a sentence.

## Load only the affected speech layer

| When the task touches | Read |
| --- | --- |
| Ownership, ordering, cancellation, fallback, queue state, or activity audio | `references/architecture-and-lifecycle.md` |
| Segmentation, boundaries, Markdown, code omission, or spoken wording | `references/narration-and-formatting.md` |
| Cloud synthesis, models, voice catalog/preview, or speech credentials | `references/elevenlabs.md` |
| `AVSpeechSynthesizer`, locale/voice selection, or `NSSound` playback | `references/macos-speech.md` |
| Tests, fakes, logs, timing, or completion verification | `references/testing-and-diagnostics.md` |
| API/toolchain/model/installed-voice drift | `references/validated-baseline.md` |

Start at the layer being changed; add lifecycle and testing references only when
the change crosses those boundaries.

Use `ux` for user-facing behavior and `testing-and-debugging` for every
diagnosis or verification.
Use `acp-integration` too when changing which ACP events become narration.

## Required workflow

1. Trace the lifecycle event through presenter, segmenter, queue, provider, and
   delegate completion. Identify who owns interruption and stale callbacks.
2. Define observable acceptance criteria for spoken text, ordering, latency,
   fallback, settings, and barge-in before editing code.
3. Add the smallest failing test with injected, silent adapters. Never require
   sound, network, credentials, or an installed voice in a unit test.
4. Preserve provider-independent orchestration. Keep cloud requests outside the
   main actor and keep speech completion delegate-driven.
5. Run focused speech tests, then the verification matrix in
   `references/testing-and-diagnostics.md`.
6. If an external contract changed, verify it against official Apple or
   ElevenLabs documentation and update the dated baseline in the same change.

## Non-negotiable rules

- Normal reply narration speaks only formatted `agentMessageDelta` content;
  the explicit `Stopped.` acknowledgement is the sole current lifecycle phrase.
  Thought, plan, tool, permission, diagnostic, and raw ACP content are
  boundaries, not narration.
- Preserve submission order even when cloud synthesis finishes out of order.
- Barge-in and cancellation stop active playback, pending synthesis, and stale
  completions immediately.
- Missing, failed, empty, or unplayable ElevenLabs output falls back to macOS
  speech without dropping or reordering the segment.
- Keep the real ElevenLabs key in Keychain. Never put it in arguments,
  preferences, fixtures, diagnostics, source, or documentation; tests use only
  obvious inert placeholders.
- Never log response text, transcripts, prompts, API keys, authorization, raw
  provider bodies, or audio. Record bounded metadata and timing only.
- Audio is never the only state signal. Respect saved settings and accessibility.

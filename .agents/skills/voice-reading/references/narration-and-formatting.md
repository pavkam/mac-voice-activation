<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Narration and spoken formatting

## What may be spoken

Only user-facing `AgentRunEvent.agentMessageDelta` text enters the segmenter.
Other event kinds are not prose to read aloud:

- thought, plan, tool, permission, and connection events flush pending reply
  prose at a semantic boundary;
- metadata, diagnostics, unknown events, and delivery notices are ignored; and
- raw ACP JSON, system prompts, user transcripts, and tool payloads never enter
  narration.

Do not infer eligibility from what happens to be visible in a debug view. Add a
typed event case and explicit policy when a new provider update should speak.

## Segmentation contract

`AgentNarrationSegmenter` preserves one message identity and up to 20,000
buffered Markdown characters.

- A period, exclamation point, or question mark ends a segment only at end of a
  line or before whitespace.
- A newline outside a fenced code block is a boundary.
- A changed message identity flushes the previous message first.
- A thought/tool/plan/permission transition flushes unfinished reply prose.
- An unfinished, non-fenced fragment gets one 350-millisecond flush deadline
  from the first buffered content. Continued deltas do not indefinitely defer it.
- Turn completion or failure flushes the remainder; cancellation resets it.
- An open triple-backtick or triple-tilde fence blocks the timer and sentence
  scanner until the fence closes or the turn finishes.

Delayed work carries a generation and returns through `MainRunLoopScheduler`.
Resetting or finishing must invalidate its task before mutating the buffer.

When the buffer exceeds its bound outside a code fence, retain the newest bounded
suffix. Inside a fence, retain only its opening marker so arbitrary code is not
later mistaken for prose. Any change here needs explicit bound and fence tests.

## Markdown-to-speech contract

`AgentMarkdownFormatter.spokenText(from:)` is shared policy:

- headings, paragraphs, list items, and quotes contribute their plain inline
  text;
- Markdown emphasis, links, and inline code lose formatting but keep readable
  characters;
- dividers are silent; and
- every fenced code block becomes the sentence `Code block omitted.`

Do not read code character by character. Do not fork a second Markdown parser in
the provider clients. Both macOS and ElevenLabs must receive the same formatted
text.

## Writing agent output for good speech

The app cannot repair every awkward response downstream. Agent-facing progress
guidance should therefore encourage:

- useful sentences with punctuation early enough to stream;
- short paragraphs and plain words for status updates;
- dates, currencies, symbols, file paths, and acronyms written with their spoken
  ambiguity in mind; and
- code in fenced blocks so it is omitted predictably.

Never mutate the visible answer only to flatter one provider. If spoken wording
must diverge, introduce an explicit, deterministic, provider-neutral spoken-text
transformation and test what users hear.

## Acceptance examples

| Streamed content | Spoken result |
| --- | --- |
| `**Done.** Next step` | `Done.` immediately, then `Next step` at a boundary/deadline. |
| Heading + list | Plain heading and list text in document order. |
| Fenced source | `Code block omitted.`; source characters are never spoken. |
| Reply fragment, then tool call | Fragment flushes before the tool boundary. |
| Thought/tool delta only | No narration. |
| New message ID | Previous buffered message speaks before the new message. |

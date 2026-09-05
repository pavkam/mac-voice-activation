<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Architecture and lifecycle

## Ownership map

| Boundary | Owner | Contract |
| --- | --- | --- |
| Eligible content | `AgentConversationAudioPresenter` | Only `agentMessageDelta` enters narration; thought, plan, tool, permission, and connection events create semantic boundaries. |
| Segmentation | `AgentNarrationSegmenter` | Buffers Markdown, emits meaningful spoken units, bounds memory, and invalidates delayed flushes. |
| Spoken rendering | `AgentMarkdownFormatter` | Removes inline Markdown, omits dividers, and replaces each code block with `Code block omitted.` |
| Speech policy snapshot | `AgentSpeechSettingsState` | Captures provider, in-memory credential, and Voice ID after settings are saved. |
| Ordering and fallback | `AgentSpeechQueue` | Owns request order, cloud lookahead, system fallback, playback state, bounds, and cancellation generations. |
| ElevenLabs synthesis | `ElevenLabsSpeechClient` | Performs the authenticated HTTPS request and returns encoded audio bytes. |
| Local speech | `SystemAgentSpeechPlayer` | Owns `AVSpeechSynthesizer`, one utterance, its selected locale voice, and delegate completion. |
| Cloud playback | `SystemAgentAudioDataPlayer` | Decodes in-memory audio with `NSSound` and reports delegate completion. |
| Activity arbitration | `AgentConversationAudioOrchestrator` | Suppresses the activity loop for `starting` and `playing`, reports audibility only for `playing`. |
| Working/tool sounds | `AgentActivitySoundLoop` | Owns delayed pulses and one-shot effects; it never synthesizes speech. |

Keep these boundaries replaceable through their existing narrow protocols. Do
not push provider-specific fields into presentation or let Settings call audio
frameworks directly.

## End-to-end flow

```text
AgentRunLifecycleEvent.event(agentMessageDelta)
  -> AgentConversationAudioPresenter
  -> AgentNarrationSegmenter
  -> AgentMarkdownFormatter.spokenText
  -> AgentConversationAudioOrchestrator
  -> AgentSpeechQueue
       -> ElevenLabsSpeechClient -> NSSound delegate
       -> or SystemAgentSpeechPlayer -> AVSpeechSynthesizer delegate
  -> next queued segment
```

The presenter flushes unfinished reply text before thought, plan, tool, or
permission activity. It resets narration and stops speech at a new run,
follow-up, turn cancellation, completed conversation, failed conversation, or
shutdown as appropriate. A cancelled conversation may enqueue the explicit
`Stopped.` acknowledgement after the queue is cleared.

## Ordering, bounds, and fallback

- The queue caps pending requests at 64. Further segments coalesce into the
  newest bounded request; combined text is capped at 20,000 characters.
- At most two ElevenLabs synthesis tasks run concurrently. They may finish out
  of order, but only the first pending request may start playback.
- A system request is ready immediately. ElevenLabs is bypassed when the cloud
  configuration is incomplete.
- An ElevenLabs error or empty result selects system speech for that same queue
  entry. Failure to decode or start cloud playback also tries system speech.
- State progresses through `preparing`, `starting`, `playing`, and `idle`.
  Cloud preparation leaves the activity sound running. `starting` silences it
  before audible playback; `playing` is the only externally reported speaking
  state.

## Cancellation and barge-in

`AgentSpeechQueue.stop()` increments its generation before cancelling synthesis,
clearing requests, and stopping both players. Every async synthesis and playback
completion carries its generation/request identity, so a retired callback cannot
restart or advance the queue.

The conversation coordinator treats the first non-empty recognized utterance
during narration as barge-in: it stops speech and continues normal follow-up
capture. Exact cancellation words stop playback and end the conversation.
Completion starts a fresh recognition session to discard captured echo. Preserve
that separation—speech playback must never own recognition state.

## Concurrency rules

- UI, orchestration, and queue mutation stay on the main actor.
- ElevenLabs synthesis runs in user-initiated detached tasks and re-enters via
  `MainRunLoopScheduler`, including modal and event-tracking run-loop modes.
- Keychain reads run on their dedicated dispatch queue; Keychain APIs are
  blocking foreign work.
- Use delegate callbacks as the playback source of truth. Do not poll
  `isSpeaking` or `isPlaying`, add guessed sleeps, or infer completion from
  encoded byte length.

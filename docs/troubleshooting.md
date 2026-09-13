<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Troubleshooting

Start with the visible symptom, then use the structured trace when the suggested
check does not identify the boundary.

## Collect the relevant diagnostics

Follow the active trace while reproducing the issue once:

```bash
voice_log_path="$HOME/Library/Logs/YapOps/yapops.jsonl"
tail -f "$voice_log_path" | jq .
```

Do not share the raw file without reviewing it. See [Diagnostics](diagnostics.md)
for correlation, timing fields, rotation, and safe extraction.

## The menu-bar icon is missing

YapOps has no Dock icon. Check the right side of the menu bar, then
confirm and relaunch the built application:

```bash
pgrep -fl YapOps
open .build/YapOps.app
```

## The status remains Starting

At application launch, startup first reconciles identifier-only interrupted
agent work. Until that bounded step finishes, shortcuts, Settings effects,
Mac-context access, credential loading, privacy prompts, passive listening, and
activation monitoring remain unavailable. If reconciliation storage is invalid,
it is quarantined and startup continues with empty continuity state.

After startup becomes ready, **Starting** means listening is enabled but speech
recognition is not ready. Complete both the Microphone and Speech Recognition
prompts. If access was denied, enable it in **System Settings > Privacy &
Security**, quit YapOps, and launch it again.

## Passive listening reports an on-device error

The selected locale has no on-device speech recognizer on this Mac. Choose
another **Speech language** in **Settings… > Speech & Audio**. Passive wake listening is
deliberately unavailable without on-device recognition.

## Capture ends without running a command

- Begin with a saved wake phrase; text before the phrase does not match.
- Wait for **Capturing**, then speak within the initial five-second window.
- A capture containing only `cancel`, `stop`, or `dismiss` is discarded.
- Check the menu error after capture and correlate the recognition generation in
  the trace.

Capture timing and cancellation rules are in
[Wake profiles](wake-profiles.md).

## A custom wake phrase does not trigger

- Confirm that exact profile is enabled in the menu.
- Use at least one letter or number; punctuation-only phrases are rejected.
- Save Settings so the new phrase reaches contextual recognition vocabulary.
- Test with the phrase at the beginning of the utterance. Longer, distinctive
  phrases usually beat acoustically ambiguous ones.

## The recording overlay is missing

The overlay appears only during matched wake capture or while push-to-talk is
held, not during passive listening. Confirm the menu reaches **Capturing**. On
multiple displays it appears on the pointer's screen when capture begins.

The overlay is intentionally non-activating, so keyboard focus remains with the
foreground application. Its close button discards the capture.

## A direct command does not run

Confirm the executable path is absolute and runnable and that at least one
argument contains `{text}` or `{urlText}`. A non-zero exit status becomes a
visible error. Standard input, output, and error are discarded, so reproduce a
new command and its arguments directly in Terminal.

See [Command targets](command-targets.md) for expansion and shell-safety rules.

## An agent profile does not start

- Confirm the executable and working folder are absolute and still exist. Use
  **Detect** or select the executable when a Finder-launched app cannot see the
  shell's full `PATH`.
- Complete the provider CLI's normal login in Terminal. YapOps does
  not collect provider credentials.
- Confirm the process supports stable ACP v1. Protocol mismatch, malformed
  frames, and oversized data fail visibly.
- If **Starting the agent** persists, wait for the startup deadline and one
  automatic fresh-process retry; the second stall becomes an error.

Provider preset and authentication details are in
[Agent providers](agent-providers.md).

## An agent lacks focused Mac context

Open **Settings… > General** and confirm **Include Mac context**
is on, then **Save Settings**. It defaults to on, but it only applies to ACP
agent requests; direct commands are intentionally unchanged.

The displayed Accessibility status refreshes without prompting. If it says
**App name only**, choose **Enable Accessibility…** and complete
macOS's prompt. YapOps never asks automatically. Before authorization,
the agent can still receive the frozen app name and bundle identifier with
`captureState: "accessibility_not_authorized"`; it cannot receive protected
window, selection, or resource values.

For an unavailable or slow target, the request continues with app identity and
`target_unavailable`, `accessibility_failed`, or `timed_out`. Native capture has
a 500 ms deadline, so waiting longer will not enrich that same turn. Say a new
follow-up after returning to the intended app; each admitted utterance captures
its own target and late or cancelled work cannot change a newer turn.

Context is bounded to app identity, an optional window title/document URL,
12 KiB of selected text, and eight selected resource references. Resource links
do not include file contents. YapOps does not resolve phrases such as
“this” or act on the snapshot; the configured ACP agent decides how to use it.
See [ACP agent harness](agent-harness.md) for the full schema and bounds.

## Agent output stops or the panel remains open

A completed turn keeps the conversation and microphone available for a
follow-up. Use **Stop turn** to cancel current provider work, narration, queued
follow-ups, and unfinished capture, or **End conversation** to return to passive
listening. Stop leaves the microphone off until **Resume listening** or an explicit
push-to-talk request. After the conversation ends,
**Close** hides retained output and **Delete** releases it.

If output does not follow the bottom, scroll there once; manual upward scrolling
intentionally owns the viewport. If the follow-up queue is full, let current
work and cancellation settle before speaking again.

A provider failure preserves useful output. The next follow-up starts a fresh
session. If a provider forgot an idle session before any observable work, YapOps retries once and shows a context-loss notice; it never replays a
request after output, a permission prompt, or tool activity.

YapOps does not persist or log focused Mac snapshot values or content;
it may record safe capture metadata. A provider may retain or replay submitted
blocks in its own session, so use that provider's retention controls when they
apply.

See [Agent conversations](agent-conversations.md) for panel controls, recovery,
and retention.

## An agent ignores the spoken-response contract

ACP v1 has no standard spoken channel, and the current marker contract is an
agent instruction rather than a provider guarantee. If an agent returns an
ordinary unmarked `agent_message_chunk`, YapOps preserves the response
as legacy text: it remains visible and, when reply reading is enabled, follows
the existing Markdown narration path. A malformed metadata extension, unknown
marker, or partial marker at a semantic boundary also falls back without dropping
or rewriting the original response.

Inspect only content-free event-kind counts:

```bash
jq -r 'select(.event == "conversation_audio.agent_event_received") |
  .fields.event_kind' "$voice_log_path" | sort | uniq -c
```

`agent_message_delta` is the legacy path. Typed or valid marker-routed responses
produce `agent_spoken_message_delta`, `agent_spoken_narration_ready`, and optional
`agent_display_message_delta` events. `agent_spoken_narration_suppressed` means
the spoken unit stayed visible but was not safe to narrate completely. Do not
capture the response, marker-adjacent text, `_meta` object, or speech bytes while
diagnosing this path.

## A previous agent conversation starts fresh

Restoration is negotiated on every provider process. YapOps does not
assume that Cursor, Codex, Claude, or a custom adapter supports an optional ACP
method because its preset did before. Missing or `null` capabilities mean
unsupported; malformed capability shapes fail the connection.

Run the safe probe from the repository root:

```bash
.agents/skills/acp-integration/scripts/probe-local-clients.sh all
```

It sends no credentials and calls only `initialize`; it does not call
authenticate, `session/new`, `session/load`, `session/resume`, `session/prompt`,
or a permission method. The provider process still inherits its normal ambient
configuration. The 2026-09-06 local run found protocol 1 on every configured
adapter: Cursor `2026.01.23-916f423` returned `loadSession: false` with no resume
capability, while Codex adapter `1.8.0` and Claude adapter `0.73.0` returned
`loadSession: true` and `resume: object`. Those are dated local results, not an
allowlist; inspect the current run.

For visible history, load is preferred and resume preserves context without
replaying history. When neither is supported, YapOps starts a fresh
session with a bounded notice. A stale saved ID or restoration replay overflow
can fall back to one fresh process only before the prompt frame. Once
`session/prompt` is written, the utterance is never retried, even when the
response says the session is missing.

Changing the provider preset, executable, ordered arguments, working folder, or
system prompt intentionally invalidates that profile's bookmark. Renaming the
provider or changing permission, wake phrase, shortcut, appearance, reply voice,
activity sounds, or Mac-context settings does not.

## A turn is marked interrupted after relaunch

The marker means active state was persisted immediately before YapOps
attempted to publish the prompt and was never successfully cleared. The frame
may or may not have reached the provider, so the app conservatively calls the
work interrupted and never replays it automatically. It does not mean the
ordinary ACP work is still running. The app converts active markers to
interrupted during launch, then reports ordinary interruption metadata once on
the next successfully published prompt for that profile. A failed frame or
durable acknowledgement keeps the marker for a later attempt.

Restored history is bounded and silent. It cannot recreate permission choices,
active historical controls, tool execution, narration, sounds, or
notifications. A complete later load replaces the older historical slice rather
than appending duplicate replay. Provider-task markers are reserved for the
separate, not-yet-implemented Background Task Continuity feature; current
ordinary work never survives process death.

## An agent is waiting for permission

With **Ask every time**, choose one exact provider option in the panel or say its
label. The existing `allow`, `allow all`, `deny`, and `deny all` shortcuts work
only when they identify one offered option. Duplicate normalized labels are
ambiguous and send nothing. The decision applies to the oldest visible request;
each response still carries its exact turn, JSON-RPC request, and option ID.

If the agent supplies valid `_meta.permission` version-1 text, the panel shows
and speech reads that exact title and optional description. Otherwise the app
uses the standard ACP tool title and exact option labels. Missing metadata is a
normal fallback, not a provider failure. A malformed title, a title over 4 KiB,
or a description over 8 KiB discards the whole extension. A complete spoken
confirmation over 20,000 characters, or one that cannot fit the speech queue,
stays visible but is silent; it is never truncated or partly spoken.

**Read replies aloud** and the profile's reply-speech choice also gate
confirmation audio. Multiple cards retain arrival order. Resolving one stops
queued speech for it and requeues only the remaining prompts. Cancelling the turn
settles every pending permission once and adds no local `Stopped.` or result
sentence. A tool completion is intentionally silent; wait for the agent-authored
message that follows it.

## Conversation speech or sounds do not play

Confirm the profile's reply-speech setting and, for inherited speech,
**Read replies aloud**; then save. Also enable **Agent activity
sounds** if those cues are missing. macOS speech uses a system voice for the
selected locale. For ElevenLabs, check the Keychain-backed API key, Voice ID,
network access, and **Test voice**. A 401 preview failure means the global API
key was not accepted; a 402 means the account needs available credits or
payment, not that the app lost the credential. A failed cloud synthesis during
a conversation falls back to macOS speech.

Typed spoken content always remains visible. When speech is enabled, the selected
backend receives only the admitted spoken unit; choosing ElevenLabs sends that
text to ElevenLabs. Legacy replies use the existing Markdown formatter.
Permission speech is limited to bounded provider presentation or the standard
tool title and exact option labels. Raw tool payloads, plans, thoughts,
diagnostics, ACP frames, and display-only text are never synthesized. Hands-free
capture pauses while speech is queued or playing. Hold push-to-talk to interrupt
and speak, or use the panel's Stop controls. Activity sounds yield to permissions
and audible narration.

If an older build repeatedly creates follow-ups from its own replies, update and
use **Stop turn** to discard the accumulated queue. A Codex model-metadata warning
is nonfatal: the pinned adapter emits it as ordinary assistant text. It can be
shown or read aloud, but must never feed another microphone request.

See [Agent conversations](agent-conversations.md) and
[Sound design](sound-design.md) for the complete behavior.

## Push-to-talk does not react

Confirm the shortcut shown for that profile, save any change, and keep the keys
held while speaking. Release submits through the selected profile. If another
application already owns the combination, YapOps reports the conflict
and restores the previous bindings.

## Listening stops after joining or leaving a call

Meeting software and audio devices can change microphone channel layout or
sample rate. YapOps rebuilds passive listening after the input
settles. If it does not recover, confirm the intended input device and both
privacy grants in System Settings, then inspect `recognition` audio-configuration
events in the trace.

## Launch at Login cannot be enabled

- Move YapOps to `/Applications` and launch that copy; do not register
  the temporary bundle under `.build`.
- Verify the bundle with `codesign --verify --deep --strict`.
- Allow YapOps under **System Settings > General > Login Items** if
  macOS requires approval, then toggle the setting again.

See [Packaging](packaging.md) for the signed bundle workflow.

## macOS asks for privacy access after every rebuild

`make app` signs with a persistent local identity by default
(`make setup-signing` provisions it once per Mac; see
[Packaging](packaging.md)), not an ad-hoc one, so this should not happen from
signing identity alone. If it still does, either identity was never
provisioned — run `make setup-signing`, then rebuild — or you built with an
explicit ad-hoc override:

```bash
SIGN_IDENTITY=- make app   # only if you passed this yourself
```

## Accessibility or another privacy grant stops working after a rebuild

Rarer, and different from the case above: the grant was working, the toggle in
**System Settings > Privacy & Security** still shows on, `Enable
Accessibility…` / **Recheck** in YapOps Settings do nothing, and the signing
identity is confirmed stable
(`codesign -d -r- .build/YapOps.app` still shows
`certificate leaf = H"..."` unchanged from before). This is macOS holding a
stale trust record for the identifier that a fresh rebuild no longer matches,
not a bug in the persistent-identity signing itself.

```bash
make reset-permissions
```

Clears Accessibility, Microphone, and Speech Recognition for `dev.alex.yapops`,
then re-grant each from a clean state: **Enable Accessibility…** in Settings,
and speak once to re-trigger the Microphone and Speech Recognition prompts.

If this recurs often during active development, `make app` keeps
`.build/YapOps.app`'s own bundle directory in place across rebuilds and only
replaces its `Contents/` — a prior version replaced the whole directory on
every build, which is a documented way for this exact class of staleness to
happen even with an unchanging signing identity. Confirm you are not on an
older checkout of `scripts/build-app.sh` before assuming this is unavoidable.

## Related guides

- [Getting started](getting-started.md)
- [Wake profiles](wake-profiles.md)
- [Command targets](command-targets.md)
- [Agent conversations](agent-conversations.md)
- [Diagnostics](diagnostics.md)
- [Privacy and security](privacy-and-security.md)

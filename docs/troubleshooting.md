# Troubleshooting

## The menu-bar icon is missing

- Voice Activation has no Dock icon; inspect the right side of the menu bar.
- Confirm the process is running:

  ```bash
  pgrep -fl VoiceActivation
  ```

- Relaunch the built bundle:

  ```bash
  open .build/VoiceActivation.app
  ```

## The status remains Disabled

Open the menu and enable listening. On first use, complete both
the Microphone and Speech Recognition privacy prompts. If they were previously
denied, enable them in System Settings, then quit and relaunch the app.

## Passive listening reports an on-device error

The selected locale does not provide on-device speech recognition on this Mac.
Choose another Apple locale identifier in Settings. This restriction applies to
passive wake detection by design; the app will not silently send always-on audio
to a service.

## Capture ends without running a command

- Begin with one of the saved wake phrases; text before it does not match.
- Speak after the status changes to **Capturing**. You may pause after the wake
  phrase; the dedicated command listener remains active for five seconds before
  timing out.
- Capture without any command text returns to passive listening after 5
  seconds. Repeated empty recognition results cannot extend this deadline.
- A completed command containing only `cancel`, `stop`, or `dismiss` is
  intentionally discarded. The same happens immediately if one of those words
  is repeated twice in a row.
- Check the menu's error text after capture. Recognition failures automatically
  restart passive listening after a short delay.

## A custom wake phrase does not trigger

- Open the menu and confirm that the toggle for that specific phrase is enabled.
- Confirm **Save Settings** completed; saved phrases are supplied to Apple
  Speech as contextual vocabulary when passive listening restarts.
- Speak the phrase at the beginning of the utterance and pause briefly while
  testing it.
- Custom spellings are supported through contextual vocabulary, but acoustically
  ambiguous phrases may still benefit from a longer, more distinctive phrase.

## The recording overlay is missing

- The overlay appears only after the wake phrase matches or while the
  push-to-talk shortcut is held; passive wake listening does not display it.
- Confirm the menu status changes to **Capturing**.
- On multiple displays, the overlay uses the screen containing the pointer when
  capture begins and remains there until that capture ends.
- The overlay never activates Voice Activation, so keyboard input remains with
  the current app. Its close button remains clickable and discards the current
  transcript without running a command.

## The direct command does not run

Check Settings for these validation requirements:

- At least one wake profile exists.
- Every wake phrase is non-empty and unique.
- Every profile URL contains `{text}` or `{urlText}`.

A non-zero process exit becomes a visible error. Standard output and standard
error are intentionally discarded, so test a new URL with `open` in Terminal
before putting it into Settings.

## An agent profile does not start

- Confirm the provider executable and working folder are absolute paths and
  still exist. Use **Detect** to search the app's inherited `PATH` and common
  macOS install locations, or select the executable directly. Finder-launched
  applications cannot rely on your interactive shell's complete `PATH`.
- Run the provider's normal login command in Terminal first. An ACP
  `auth_required` response is shown in the panel with the provider-advertised
  authentication methods; Voice Activation does not collect credentials.
- Confirm the provider supports stable ACP version 1. Incompatible protocol
  versions and malformed or oversized messages fail the run visibly.
- Cursor's native server is normally launched as `cursor-agent acp`. The Codex
  and Claude presets use their pinned `npx` adapter arguments.

## Agent output stops or the panel remains open

Turn completion intentionally keeps both the panel and conversation microphone
open for follow-ups. Speak another request to continue in the same ACP session.
Use **Stop turn** to cancel only active work, or **End conversation** to return
to passive wake listening. After the conversation ends, choose **Close** to hide
the retained output. Saying only `stop`, `cancel`, or `dismiss` stops active
work; saying it while the agent is waiting ends the conversation.

If new output does not follow the bottom, scroll to the bottom once. A deliberate
scroll upward pauses automatic following so earlier output remains readable.

If a provider exits, emits invalid JSON, exceeds a protocol bound, or closes a
pipe unexpectedly, the panel enters a failed state with bounded diagnostics.
The failed process is discarded and a later trigger starts a fresh connection.

## An agent is waiting for permission

With **Ask**, choose one of the exact options supplied by the provider in the
panel. The app does not invent a broader approval. **Allow once** selects a
one-shot approval when offered; **Reject** returns a rejection or cancelled
outcome. Cancelling the run also cancels every pending permission request.

## Conversation speech or sounds do not play

Confirm **Read replies aloud** and **Working pulse** are enabled in Settings and
that **Save Settings** succeeded. Voice Activation uses the configured locale's
macOS system voice and obeys the current output volume. The working pulse waits
1.6 seconds before its first low-volume cue, so quick turns stay quiet.

The capture start cue plays only when capture begins; the end cue plays for
submission, cancellation, timeout, and capture errors.

## Push-to-talk does not react

The first profile defaults to Control-Option-Space. Every assigned combination
appears next to its profile in the menu and can be changed inside that profile’s
Settings card. Select **Save Settings** to register the new binding set. Another
application may own a requested shortcut first; Voice Activation reports that
conflict and restores all previous bindings. Keep the keys held while speaking
and release them to submit through the selected profile.

## Listening stops after joining or leaving a call

Meeting software and audio devices can change the microphone's channel layout or
sample rate. macOS stops active audio engines when that happens. Voice Activation
automatically rebuilds its passive listener after the input settles; the menu may
briefly show **Listening** while that recovery completes.

If listening does not resume after a few seconds, confirm the intended microphone
is still selected in System Settings and that Voice Activation retains Microphone
and Speech Recognition access.

## Launch at Login cannot be enabled

- Move Voice Activation to `/Applications` and launch that copy before enabling
  the option. Do not register the temporary bundle under `.build`.
- Confirm the app bundle is code-signed with `codesign --verify --deep --strict`.
- Open **System Settings › General › Login Items** and allow Voice Activation if
  macOS says approval is required.
- Return to Voice Activation Settings and toggle the option again. Registration
  errors appear directly below the toggle.

## macOS asks for privacy access after every rebuild

The default development build is ad-hoc signed. Its identity changes when the
executable changes, so macOS can request access again. Use a stable Apple
Development signing identity and launch a stable copy from Applications:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make app
```

See [Getting started](getting-started.md) for the complete build flow.

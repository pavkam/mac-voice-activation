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

## The command does not run

Check Settings for these validation requirements:

- At least one wake profile exists.
- Every wake phrase is non-empty and unique.
- Every profile URL contains `{text}` or `{urlText}`.

A non-zero process exit becomes a visible error. Standard output and standard
error are intentionally discarded, so test a new URL with `open` in Terminal
before putting it into Settings.

## Capture sounds do not play

Voice Activation uses macOS system sounds and obeys the current output volume.
Confirm the Mac is not muted and that alert volume is audible in System Settings.
The start cue plays only when capture begins; the end cue plays for submission,
cancellation, timeout, and capture errors.

## Push-to-talk does not react

The default shortcut is Control-Option-Space. The active combination appears in
the menu and can be changed by clicking it in Settings, recording a combination,
and selecting **Save Settings**. Another application may have registered the
requested global shortcut first; Voice Activation reports that conflict and keeps
the previous shortcut. Keep the keys held while speaking and release them to
submit.

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

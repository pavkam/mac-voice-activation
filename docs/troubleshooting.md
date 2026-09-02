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

Open the menu and enable **Listen for “computer”**. On first use, complete both
the Microphone and Speech Recognition privacy prompts. If they were previously
denied, enable them in System Settings, then quit and relaunch the app.

## Passive listening reports an on-device error

The selected locale does not provide on-device speech recognition on this Mac.
Choose another Apple locale identifier in Settings. This restriction applies to
passive wake detection by design; the app will not silently send always-on audio
to a service.

## Capture ends without running a command

- Begin with the wake phrase; text before it does not match.
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

- The executable path is absolute, exists, and is executable.
- At least one argument contains `{text}` or `{urlText}`.
- Every intended process argument occupies its own line.

A non-zero process exit becomes a visible error. Standard output and standard
error are intentionally discarded, so test a new command in Terminal before
putting it into Settings.

## Push-to-talk does not react

The shortcut is Control-Option-Space. Another application may have registered
the same global shortcut first; remove that conflict and relaunch Voice
Activation. Keep the keys held while speaking and release them to submit.

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

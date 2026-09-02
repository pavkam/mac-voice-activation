# Getting started

## Requirements

- macOS 15 or later
- Swift 6.2 or later
- Xcode Command Line Tools or Xcode

Confirm the active toolchain:

```bash
swift --version
xcodebuild -version
```

## Clone and verify

```bash
git clone https://github.com/pavkam/mac-voice-activation.git
cd mac-voice-activation
make test
make app
```

The packaged application is written to:

```text
.build/VoiceActivation.app
```

Launch it with:

```bash
open .build/VoiceActivation.app
```

Voice Activation is a menu-bar agent, so it does not appear in the Dock. Look
for its status icon on the right side of the menu bar.

## Grant permissions

The first voice action requests two macOS privacy permissions:

1. Microphone access, to capture audio.
2. Speech Recognition access, to transcribe that audio.

Both permissions are required. If either is denied, enable Voice Activation in
the corresponding Privacy & Security section of System Settings, quit the app,
and launch it again.

## Run the first command

The default configuration opens a Google search:

1. Wait until the menu-bar status says **Listening**.
2. Say `computer`.
3. When the recording overlay appears, say a search query. Partial command text
   appears below its animated microphone.
4. Stop speaking; the overlay closes and the command is submitted when
   recognition finalizes or the transcript is unchanged for 1.5 seconds.

Click the close button on the recording orb or choose **Cancel Recording** from
the menu to discard the current capture without running its command.

You can also hold Control-Option-Space, speak without a wake phrase, and release
the keys to submit.

## Development signing

`make app` uses an ad-hoc signature by default. macOS may request privacy access
again after the executable changes. To sign with an installed identity:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make app
```

For regular use, move the completed app bundle to `/Applications` in Finder and
launch that stable copy instead of rebuilding it in place. You can then enable
**Launch at Login** in Settings without registering a disposable build path.

Next: [configure commands and wake behavior](configuration.md).

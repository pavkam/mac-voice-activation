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

A short start sound confirms that capture began. A different end sound confirms
that capture stopped, whether it submits, times out, or is cancelled.

Click the close button on the recording orb or choose **Cancel Recording** from
the menu to discard the current capture without running its command.
You can also say only `cancel`, `stop`, or `dismiss`. Repeat the same word twice
to cancel immediately without waiting for speech recognition to finalize.

You can also hold a profile’s push-to-talk shortcut shown in the menu, speak
without a wake phrase, and release the keys to submit through that profile. The
first profile defaults to Control-Option-Space. Assign or remove a binding inside
each profile card in Settings, then select **Save Settings**.

## Development signing

`make app` uses an ad-hoc signature by default. macOS may request privacy access
again after the executable changes. To sign with an installed identity:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make app
```

For regular use, move the completed app bundle to `/Applications` in Finder and
launch that stable copy instead of rebuilding it in place. You can then enable
**Launch at Login** in Settings without registering a disposable build path.

## Run a local coding agent

Install and authenticate a supported ACP provider first. Then open
**Settings…**, edit a wake profile, and:

1. Change **Target** from **Command** to **Agent**.
2. Choose Cursor, Codex, Claude, or Custom.
3. Confirm the detected absolute executable path and choose an absolute working
   folder.
4. Select **Ask**, **Allow once**, or **Reject** for tool permissions.
5. Select **Save Settings**.

Trigger that phrase and speak the task. The recording overlay morphs into a
non-activating agent panel that streams an ordered Markdown response while your
current app keeps keyboard focus. Running tools use animated compact rows;
finished tools and answered permission prompts collapse out of the way, with
tool details still expandable. Completed output remains available to select or
copy.

Provider credentials remain in the provider's own CLI configuration; Voice
Activation does not ask for or persist them. Continue with the
[ACP agent harness guide](agent-harness.md).

Next: [configure wake profiles and capture behavior](configuration.md).

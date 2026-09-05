<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# macOS speech and playback

Validated against production code, Apple documentation, and the local macOS
command-line surface on 2026-09-05.

## Local speech contract

`SystemAgentSpeechPlayer` retains one `AVSpeechSynthesizer` and one active
`AVSpeechUtterance`. For each segment it:

1. stops any owned utterance;
2. creates `AVSpeechUtterance(string:)`;
3. selects `AVSpeechSynthesisVoice(language: localeID)`;
4. sets rate to `AVSpeechUtteranceDefaultSpeechRate * 0.94` and pitch to `1.02`;
5. calls `speak(_:)`; and
6. completes through `didFinish` or `didCancel` for the identical utterance.

Apple describes the utterance as the basic synthesis unit and recommends
delegate callbacks for meaningful units:
[AVSpeechUtterance](https://developer.apple.com/documentation/avfaudio/avspeechutterance),
[AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer).
Apple also documents language/locale as the main voice-selection dimensions and
provides `speechVoices()` for device inventory:
[AVSpeechSynthesisVoice](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoice).

Do not rely on `AVSpeechSynthesizer`'s internal multi-utterance queue; the app's
`AgentSpeechQueue` is the cross-provider ordering authority. Retain the
synthesizer and active utterance until its callback. On stop, clear owned state
before calling `stopSpeaking(at: .immediate)` so cancellation callbacks cannot
complete a retired request.

## Locale and voice availability

The app chooses a system voice by the saved speech locale, not by a pinned voice
identifier. The utterance text should match that BCP 47 language/locale as
closely as possible; Apple notes this improves phoneme and regional-pronunciation
selection. `AVSpeechSynthesisVoice(language:)` is optional, so never force-unwrap
it.

Installed voices vary by Mac, OS version, downloads, and user choices. Never
hardcode the local `say -v '?'` list or make tests depend on a named voice. For
manual inventory only:

```bash
say -v '?'
```

The `say` CLI is a diagnostic aid, not the app implementation. Do not invoke it
from production code or unit tests, and do not play a sample without explicit
user intent.

## Cloud-audio playback

ElevenLabs returns MP3 data in memory. `SystemAgentAudioDataPlayer` constructs
`NSSound(data:)`, retains it and its completion, and uses
`NSSoundDelegate.sound(_:didFinishPlaying:)` as the terminal signal. Apple
documents that delegate callback as carrying whether playback completed
successfully:
[NSSoundDelegate completion](https://developer.apple.com/documentation/appkit/nssounddelegate/sound%28_%3Adidfinishplaying%3A%29).

Decode or start failure must return `false` synchronously so the queue can start
system speech for the same segment. `stop()` removes the delegate before stopping
and clearing state. Never persist cloud audio to disk merely to play it.

## Interaction and accessibility

- Playback must yield immediately to barge-in, explicit stop, a new turn, saved
  settings disabling narration, conversation end, and app shutdown.
- System volume and output routing belong to macOS; do not duplicate them in app
  preferences.
- Voice reading supplements the visible panel. Audio cannot be the sole carrier
  of completion, failure, permission, or tool state.
- Keep recognition active during reply playback as designed. Voice-processing
  input is best-effort echo reduction, not a guarantee; unsupported devices must
  still capture normally.

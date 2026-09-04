<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Sound design

Voice Activation uses one restrained glass-and-air sound family. Every effect
is bundled with the app, so listening and agent activity remain instant and do
not depend on a network request.

## Cue map

| Event | Asset | Duration | Playback |
| --- | --- | ---: | --- |
| Command capture begins | `CaptureStart.wav` | 0.68 s | Once per capture edge. |
| Command capture ends | `CaptureEnd.wav` | 0.64 s | Once per capture edge. |
| Agent remains busy | `AgentThinking.wav` | 0.64 s | After 1.6 s, then every 3.2 s while work continues. |
| Tool becomes active | `ToolStart.wav` | 0.52 s | Once per tool and turn. |
| Tool completes | `ToolComplete.wav` | 0.52 s | Once when that tool reaches completion. |
| Tool fails | `ToolFailed.wav` | 0.60 s | Once when that tool reaches failure. |

ACP providers may repeat pending, in-progress, or terminal tool updates. The
audio presenter normalizes those updates into active, completed, and failed
phases, then plays only phase transitions. Starting a new turn clears the tool
sound state.

The **Agent activity sounds** setting controls thinking and tool cues. Capture
start and end remain independent confirmations of microphone state. Reply
narration pauses the repeating thinking cue and resumes its delay if the agent
continues working afterward.

## Asset generation

The six effects were generated once with the ElevenLabs
[Sound Effects API](https://elevenlabs.io/docs/api-reference/text-to-sound-effects/convert)
using `eleven_text_to_sound_v2`, explicit sub-second durations, non-looping
output, and `0.65` prompt influence. The shared prompt direction asks for
premium, subtle glass and air interface sounds without voices, percussion,
heavy bass, alarms, or long reverb tails.

Generation returned 44.1 kHz MP3 audio. The committed assets are mono, 48 kHz,
16-bit PCM WAV files for predictable AppKit playback. The API credential came
from the app's Keychain item and was never written to the repository. Runtime
effect playback never contacts ElevenLabs; only optional reply narration does.

Tests replace every sound boundary with silent spies. Running the test suite
does not play these assets or contact ElevenLabs.

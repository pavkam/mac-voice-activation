<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Validated baseline

This is a source-dated snapshot, not timeless truth. Recheck drift-prone details
before changing compatibility. Authority order is live production code and
tests, official vendor documentation, then this baseline.

## Repository baseline — 2026-09-05

- Package contract: Swift tools 6.2, macOS 15 minimum, Swift Testing dependency
  pinned to `swift-6.2.2-RELEASE`.
- Active local compiler: Apple Swift 6.3.3 targeting arm64 macOS 26.0.
- Full Xcode is not selected; `xcodebuild` reports the active developer directory
  is Command Line Tools. Do not treat Xcode-only UI workflows as validated here.
- Narration: 350-millisecond first-fragment deadline, 20,000-character buffer,
  punctuation/newline/semantic/message boundaries, fenced-code suppression.
- Queue: 64 pending entries, 20,000-character coalesced bound, two concurrent
  cloud synthesis tasks, ordered playback, generation-based cancellation.
- System voice: `AVSpeechSynthesisVoice(language:)`, rate multiplier `0.94`,
  pitch `1.02`, immediate stop, delegate completion/cancellation.
- ElevenLabs speech: `POST /v1/text-to-speech/{voice_id}/stream`,
  `mp3_44100_128`, model `eleven_flash_v2_5`, 30-second timeout.
- ElevenLabs voice catalog: `GET /v2/voices`, page size 100, name ascending,
  20-second timeout, maximum ten pages.
- Cloud playback: in-memory `NSSound(data:)` with delegate completion.
- Credentials: generic-password Keychain item, dedicated read queue, optional
  standard-input bootstrap. No key is stored in preferences or source.

## Official external baseline — checked 2026-09-05

- ElevenLabs' [stream speech endpoint](https://elevenlabs.io/docs/api-reference/text-to-speech/stream)
  still matches the path, Voice ID parameter, header, and MP3 format in code.
- ElevenLabs' [models page](https://elevenlabs.io/docs/overview/models) lists
  `eleven_flash_v2_5`, 32 languages, and a 40,000-character service limit.
- ElevenLabs' [voice search endpoint](https://elevenlabs.io/docs/api-reference/voices/search)
  documents `/v2/voices`, `has_more`/`next_page_token`, and page sizes through
  100.
- Apple documents `AVSpeechUtterance` + `AVSpeechSynthesizer` as the supported
  synthesis path, `AVSpeechSynthesisVoice` for locale/device voices, delegate
  callbacks for completion, and `NSSoundDelegate` for sound-data completion.
- Apple documents `SecItemCopyMatching` as blocking; the dedicated queue remains
  required.

## Local CLI observations — 2026-09-05

- `/usr/bin/say` is available. `say -v '?'` reports 184 installed entries across
  50 advertised locales on this Mac. This is machine-specific inventory, not a
  compatibility promise and not a unit-test fixture.
- No `elevenlabs`, `eleven`, or `elevenlabs-cli` executable is installed.
- No real audio was played, no Keychain value was read, and no authenticated
  ElevenLabs request was made while establishing this baseline.

## Refresh checklist

Update this file when a model, endpoint, format, voice-selection strategy,
timeout, bound, minimum OS, or toolchain changes. Record the exact date and
evidence. Never record credential values, installed voice names, raw service
responses, transcripts, or transient logs.

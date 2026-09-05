<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# ElevenLabs integration

Validated against production code and official ElevenLabs documentation on
2026-09-05. Live code is authoritative for current app behavior; official docs
are authoritative for the remote API.

## Current synthesis contract

`ElevenLabsSpeechClient` sends:

```http
POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}/stream?output_format=mp3_44100_128
Content-Type: application/json
xi-api-key: <Keychain value>
```

The JSON body contains:

```json
{
  "text": "<spoken segment>",
  "model_id": "eleven_flash_v2_5",
  "voice_settings": {
    "stability": 0.45,
    "similarity_boost": 0.75,
    "style": 0.0,
    "use_speaker_boost": true,
    "speed": 1.0
  }
}
```

The request timeout is 30 seconds. A Voice ID is accepted only when non-empty
and made of letters, digits, hyphen, or underscore. Any non-2xx response is
reduced to its status code; response bodies must not enter user errors or logs.
An empty success is an error. The queue converts any of these failures into the
macOS fallback for the same segment.

The official [stream speech API](https://elevenlabs.io/docs/api-reference/text-to-speech/stream)
confirms the endpoint, Voice ID path parameter, `xi-api-key` header, and
`mp3_44100_128` format. The app currently buffers the returned body before
playback; the endpoint name does not mean incremental playback is implemented.

## Model and voice settings

The app pins `eleven_flash_v2_5`; do not silently replace it with a newer model.
ElevenLabs lists Flash v2.5 as a low-latency, 32-language model with a 40,000
character request limit in its [model documentation](https://elevenlabs.io/docs/overview/models).
The app deliberately applies the stricter 20,000-character bound.

The current values follow ElevenLabs' typical stability/similarity/style
starting point while choosing slightly lower stability. Treat changes as product
behavior: preview several representative voices and test pronunciation,
consistency, latency, and cancellation. The official
[voice settings guide](https://elevenlabs.io/docs/eleven-creative/playground/text-to-speech)
notes that generation is nondeterministic, style above zero can add latency and
instability, speaker boost adds some work, and speed supports 0.7 through 1.2.

Flash v2.5 does not normalize numbers, dates, and currencies as strongly by
default. Do not add provider markup to visible replies. If normalization is
needed, design a provider-neutral spoken-text transform with explicit tests.

## Voice catalog and preview

`ElevenLabsVoiceCatalogClient` requests `GET /v2/voices` with a 20-second
timeout, `page_size=100`, name ascending sort, and `xi-api-key`. It follows
`has_more` plus `next_page_token`, deduplicates IDs, sorts names, and rejects
cycles or more than ten pages. The official [list voices API](https://elevenlabs.io/docs/api-reference/voices/search)
confirms the endpoint, 100-item maximum, and pagination contract.

Settings may retain a manually entered Voice ID if the catalog is unavailable.
Preview reuses the synthesis client with a short fixed sentence, owns its own
generation, and must reject stale audio after cancellation. Preview failure does
not change the saved provider.

## Credential and privacy contract

- The API key is a generic-password Keychain item. `AppPreferences` stores only
  provider choice and Voice ID.
- Startup reads the key on a dedicated queue. Saving updates/adds/deletes the
  Keychain item; optional bootstrap imports the key from standard input, never
  from a command-line value.
- When ElevenLabs is selected, the already formatted spoken segment leaves the
  Mac. Never send thought, tool, plan, permission, diagnostic, code contents, or
  raw ACP data.
- Diagnostics may include request identity, timing, status, character count,
  and byte count. They must exclude headers, keys, request text, and bodies.
- Never probe the authenticated service during ordinary tests or validation.

Apple documents Keychain as encrypted storage for small secrets and warns that
Keychain item operations block; keep them off the main thread:
[Keychain services](https://developer.apple.com/documentation/security/keychain-services),
[SecItemCopyMatching](https://developer.apple.com/documentation/security/secitemcopymatching%28_%3A_%3A%29).

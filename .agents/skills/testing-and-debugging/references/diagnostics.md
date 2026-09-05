<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Structured diagnostics

The app installs `JSONLVoiceActivationDiagnosticRecorder` at startup. This
JSONL trace—not ad hoc `print` calls—is the repository's runtime diagnostic
contract.

## Storage and bounds

- Active file: `~/Library/Logs/VoiceActivation/voice-activation.jsonl`
- Rotation: 5 MiB active file plus `.1`, `.2`, and `.3`
- Writer: dedicated serial user-initiated queue; shutdown flushes it
- Schema version: `1`
- Event name: 160 characters maximum
- Field key: 120 characters maximum
- Field value: 512 characters maximum and forced onto one line

Field names containing `api_key`, `authorization`, `content`, `credential`,
`prompt`, `secret`, `text`, `token`, or `transcript` are replaced with
`<redacted>`. This is defense in depth, not permission to pass sensitive data
to the recorder.

Each record contains `schema_version`, `timestamp`, `uptime_ms`,
`session_elapsed_ms`, `session_id`, `sequence`, `process_id`, `main_thread`,
`category`, `event`, `level`, and `fields`. Categories are `app`, `settings`,
`ui`, `hot_key`, `speech_recognition`, `command`, `acp`, `agent`, `audio`, and
`network`.

## Inspect without spraying logs everywhere

Start with shape and aggregates. Narrow to the relevant session/run before
looking at individual records, and never paste an unreviewed raw log into chat,
an issue, or a fixture.

```bash
voice_log_path="$HOME/Library/Logs/VoiceActivation/voice-activation.jsonl"
jq -s 'group_by(.category) | map({category: .[0].category, count: length})' "$voice_log_path"
jq 'select(.level == "error" or .level == "warning")' "$voice_log_path"
jq 'select(.session_id == "SESSION-ID") | {sequence, session_elapsed_ms, category, event, level, fields}' "$voice_log_path"
jq 'select(.fields.run_id == "RUN-ID") | {sequence, session_elapsed_ms, category, event, level, fields}' "$voice_log_path"
```

Use `session_id` and `sequence` for process-local ordering. Preserve and
correlate `run_id`, ACP session/request identifiers, turn/generation values,
and profile IDs where present. For stalls compare `queue_delay_ms`,
`duration_ms`, `main_delivery_ms`, `run_loop_mode`, and `task_priority`. A
started event without the corresponding finished, failed, rejected, or
cancelled event identifies the boundary to investigate; it does not by itself
prove the implementation cause.

## Add diagnostics as a contract

- Use a stable `subsystem.action` event name and a category already owned by
  the subsystem.
- Record state, counts, booleans, bounded identifiers, error *types*, timing,
  and admission/outcome—not user or provider content.
- Pair long operations with started and terminal events. Use monotonic timing
  for durations and wall time only for human correlation.
- Inject `VoiceActivationDiagnosticRecording`; assert events with a recorder
  spy. Test redaction/rotation only at the JSONL recorder boundary.
- Do not record every token, audio buffer, polling tick, or repeated idle state.
  Diagnostics must remain bounded under the failure they diagnose.

If recorder initialization fails, startup emits one bounded message to stderr.
Production code otherwise has no parallel `Logger`, `NSLog`, or `print` logging
path to reconcile.

<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Experience principles and surface contracts

Voice Activation is an ambient macOS utility, not a miniature dashboard. It
should disappear when idle, respond instantly when summoned, explain its state
without demanding attention, and preserve the foreground app's focus.

## Product feel

- **Peripheral by default:** show only the state and action needed now.
- **Glanceable:** pair short copy with a symbol, shape, and semantic color.
- **Continuous:** wake, capture, execution, conversation, and dismissal should
  feel like phases of one interaction rather than unrelated windows.
- **Calm under load:** streaming output can be busy; the surrounding chrome is
  stable. Do not animate every token or tool update.
- **Truthful:** show starting, listening, working, cancelling, failed, and
  completed states distinctly. Never hide latency behind fake progress.
- **Reversible:** cancellation, minimizing, restoration, and destructive
  actions remain obvious and preserve the user's context.
- **Respectful:** no focus theft, surprise activation, unnecessary notification,
  or persistent audio.

## Surface contracts

### Menu-bar menu

`MenuContentView` is the compact control center. Lead with current status, then
contextual agent controls, profile toggles, capture cancellation, and app
actions. Keep the hierarchy shallow and use familiar macOS controls. Opening a
menu is already an interaction; avoid ornamental entrance choreography.

### Recording overlay

`RecordingOverlayView` is transient and bottom-centered. The compact microphone
orb expands horizontally when useful transcript text appears. It must expose an
immediate cancel action, keep the current profile accent, and remain a
non-activating `NSPanel`. Recording state needs a visual signal even when sound
is muted or unavailable.

### Agent conversation panel

The recording overlay hands its frame to the agent panel so capture becomes
conversation without teleporting. Expanded mode prioritizes the request,
ordered timeline, current permissions, and phase-specific actions. Compact mode
is a glanceable top-right notification and restores to the user's saved expanded
position. Programmatic bottom-follow continues only while the user remains near
the bottom; manual scrolling owns the viewport.

### Settings

`SettingsView` is a regular activating window. Favor standard controls,
descriptive sections, explicit save feedback, keyboard defaults, and plain
privacy explanations. Settings can be denser than the ambient surfaces, but
related options stay together and advanced provider details appear only when
the selected configuration needs them.

### Sound and speech

Capture, thinking, and tool cues form one restrained glass-and-air family.
Sounds confirm state edges; they do not become a metronome. Spoken replies yield
to recognition and visual state. Every important audio cue has equivalent
visible status and control.

## Interaction review

For each change, write the sequence as cause → visible response → settled state.
If two surfaces show the same state, their copy, symbol, available action, and
accent must agree. If they disagree, fix the presentation mapping rather than
papering over one view.

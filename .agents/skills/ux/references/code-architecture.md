<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# UX code architecture and modularization

Choose boundaries by ownership and behavior, not by how many lines a view body
has today.

## Ownership map

- Domain state and legal transitions belong to `VoiceActivationCore`, as in
  `ActivationState` and `VoiceActivationCoordinator`.
- App-wide UI coordination belongs to `@MainActor AppModel` and its lifecycle,
  configuration, and conversation extensions.
- State-to-copy and symbol mapping belongs in pure presentation values such as
  `MenuStatusPresentation` and `MenuListeningControlPresentation`.
- Retained surface state belongs in a surface model or presenter, as in
  `AgentRunPanelModel` and `AgentRunPanelPresenter`.
- Geometry and screen clamping belong in pure layout types such as
  `AgentRunPanelLayout` and `RecordingOverlayLayout`.
- Declarative rendering belongs in the menu, overlay, panel, and Settings
  SwiftUI views.
- Window level, focus, frame, and Spaces behavior belong in the AppKit panel and
  overlay controllers.
- Reusable drawing or interaction belongs in a focused primitive or style such
  as the phase orb, action button style, or drag surface.

Do not put process launch, persistence, network work, timers, or state-machine
decisions in a view. Do not make Core know about `Color`, `Animation`, `NSPanel`,
or screen coordinates.

## Split by responsibility

- Keep a composition view readable as the map of the surface. Extract a named
  section when it owns a distinct interaction, state branch, animation, or test
  boundary—not merely to shorten the file.
- Split large retained types with same-module
  `Type+Responsibility.swift` extensions so identity and state ownership remain
  obvious. The agent panel and `AppModel` already use this pattern.
- Put pure formatting, geometry, phase mapping, and motion policy in value types
  that Swift Testing can exercise without opening a window.
- Keep one-use visual fragments private and near their surface. Extract a shared
  primitive after two real surfaces need the same semantics and evolution.
- Prefer a concrete dependency until replacement is useful. Add protocols at
  framework, lifecycle, process, audio, pasteboard, or other side-effect seams.
  A protocol for one pure formatter is ceremony wearing a nice coat.
- Keep stable identity from the model through `ForEach`, timeline entries,
  tools, permissions, and transitions. Array indices are not identity.

## Presentation before pixels

When state produces user-facing copy, symbols, roles, or available actions,
map it once in a pure presentation type. Views consume that value. This prevents
the menu, recording overlay, agent panel, and accessibility labels from inventing
slightly different meanings for the same phase.

Keep asynchronous generations, run IDs, and turn tokens intact through
presentation. A stale callback must not animate or repopulate a newer surface.
Animation never grants old state another chance to win.

## Visual primitives and tokens

Name shared values by meaning: `panelMorph`, `pressedControl`, `statusFailure`,
or `profileAccent`. Avoid `purple500`, `duration2`, and generic style factories.
Centralize a value only when changing it should intentionally affect every
consumer.

The profile accent-highlight mapping currently appears in the recording overlay
and agent panel. If a feature touches both, consolidate it into one App-owned
palette value and cover every `WakeProfileAccent`; do not launch an unrelated
refactor just to satisfy abstraction aesthetics.

## AppKit and SwiftUI boundary

SwiftUI owns content transitions. AppKit owns panel frames and activation.
Coordinate both from the same state edge and semantic duration. The controller
must remain the authority for screen selection, negative screen origins,
visible-frame clamping, panel level, and `canBecomeKey`/`canBecomeMain` behavior.

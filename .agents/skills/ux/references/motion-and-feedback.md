<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Motion and feedback

Motion explains causality, state change, and spatial continuity. It does not
exist to prove that SwiftUI has an animation API.

## Project rhythm

Use these ranges as the current rhythm, then keep one semantic duration as the
source of truth for all layers participating in the transition:

| Moment | Typical duration | Character |
| --- | ---: | --- |
| Press feedback | 0.10–0.14 s | Immediate scale or opacity response |
| Text or scroll settlement | 0.16–0.22 s | Short interpolation or ease-out |
| Action replacement | 0.24–0.32 s | Snappy, low-bounce transition |
| Overlay or panel morph | 0.36–0.44 s | Smooth spatial continuity |
| Busy pulse or rotation | 1.0–1.4 s | Quiet repeating status signal |

Do not stack several unrelated animations on one state edge. Choose the single
story: a control replaced, a surface expanded, an item inserted, or attention
moved.

## SwiftUI pattern

Read Reduce Motion at the surface boundary, derive animation and transition
from it, and scope animation to the state that causes the change:

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

private var phaseAnimation: Animation {
    reduceMotion ? .easeOut(duration: 0.14) : .snappy(duration: 0.30)
}

private var phaseTransition: AnyTransition {
    reduceMotion
        ? .opacity
        : .move(edge: .bottom).combined(with: .opacity)
}

var body: some View {
    phaseContent
        .transition(phaseTransition)
        .animation(phaseAnimation, value: phase)
}
```

Use `contentTransition(.interpolate)` or `.numericText` for changing content
when it communicates continuity. Use a symbol effect for a symbol, not as a
substitute for state copy. `PhaseAnimator` suits a few discrete visual phases;
`KeyframeAnimator` is justified only when independent tracks explain one
interaction. Its content closure runs every frame, so it remains rendering-only.

An unscoped `.animation` high in a hierarchy is forbidden. It makes unrelated
state drift and turns debugging into interpretive dance.

## Repeating motion

Mount repeating pulses, rotations, and symbol effects only while their state is
active. Remove them when work stops or the view disappears. Under Reduce Motion,
show a static ring, symbol, label, or opacity state; do not merely slow a forever
animation.

Streaming text publishes at the existing bounded cadence. Animate structural
events such as a message appearing or a tool settling, not every token. Preserve
stable IDs so insertion and replacement transitions describe the correct item.

## AppKit frame animation

SwiftUI content and `NSPanel` frame changes start from the same state edge and
share the same semantic duration. Before using `panel.animator()`, read
`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`. When true, set the
settled frame directly or use a short cross-fade without spatial scaling.
Long-lived controllers observe
`accessibilityDisplayOptionsDidChangeNotification` when they cache display
preferences.

Never animate panel activation. Recording and agent panels remain
non-activating throughout morph, minimize, restore, drag, and permission work.

## Sound and feedback

Sound confirms meaningful state edges: capture start/end, sustained work, and
tool start/completion/failure. Normalize duplicate provider events before
playing cues. Pause activity sound for speech and resume only if work continues.

Pressed, hover, visual state, and sound all reinforce the same action. Sound is
supplemental: mute, device routing, or hearing differences must not hide an
important state or required action.

---
name: ux
description: Use when designing, implementing, reviewing, or testing UI or UX, including SwiftUI or AppKit views, menu-bar behavior, floating panels, Settings, presentation models, layout, visual styling, animation, sound feedback, accessibility, or interaction polish.
---

<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# UX

Make the app feel immediate, calm, and unmistakably native. Slick means state
continuity, legibility, restraint, and fast feedback—not more decoration.

## Load only the affected surface

| When the task touches | Read |
| --- | --- |
| Product feel, menu, overlay, panel, Settings, or interaction contract | `references/experience-principles.md` |
| Ownership, modularization, presentation models, AppKit/SwiftUI boundaries | `references/code-architecture.md` |
| Color, materials, typography, symbols, spacing, or reusable styling | `references/visual-language.md` |
| Animation, scrolling, transitions, timing, sound, or feedback | `references/motion-and-feedback.md` |
| Accessibility, performance, tests, or completion validation | `references/accessibility-and-validation.md` |
| A new or uncertain Apple framework API/convention | `references/apple-platform-guidance.md` |

Read the experience contract for user-visible changes, then only the references
for the affected implementation and validation boundaries.

## Shape the change

1. Trace the affected moment from domain state through presentation, SwiftUI,
   AppKit hosting, and user action. Name the user-visible cause and effect.
2. Define observable acceptance criteria: what appears, moves, remains stable,
   receives focus, and happens with accessibility settings enabled.
3. Add the smallest failing deterministic test at the lowest useful boundary.
4. Put behavior in Core, semantic mapping in presentation types, geometry in
   pure layout helpers, rendering in SwiftUI, and window lifecycle in AppKit.
5. Implement one coherent visual or interaction story. Prefer macOS system
   components and semantic values over custom chrome.
6. Verify the focused behavior and the matrix in
   `references/accessibility-and-validation.md`.

## Quality gate

A UX change is ready only when:

- the primary state and action are clear at a glance;
- appearance, copy, symbols, motion, and sound describe the same state;
- repeated updates preserve identity, scroll intent, and input focus;
- a non-activating panel remains non-activating and never becomes key or main;
- Reduce Motion substitutes fades or static state for spatial/repeating motion;
- Reduce Transparency and Increase Contrast retain legibility;
- color and audio are never the only state signal;
- streaming or animation adds no blocking work, unbounded state, or per-token
  task churn; and
- every API works on macOS 15 or has an explicit availability guard and fallback.

Do not create a generic design system for one use, animate an entire hierarchy
with an unscoped `.animation`, or polish over a broken state model. Fix the
experience boundary first; the pixels can then behave themselves.

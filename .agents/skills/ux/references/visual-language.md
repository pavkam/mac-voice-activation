<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Visual language

Voice Activation uses soft continuous geometry, semantic system colors,
profile accents, restrained material, and SF Symbols. The personality comes from
consistent hierarchy and tiny responsive details—not a pile of gradients.

## Layering recipe

Build a floating surface in this order:

1. a semantic material or opaque accessibility fallback;
2. one low-opacity profile tint that establishes identity;
3. a subtle border or separator that restores edge definition;
4. high-contrast content using primary and secondary semantic styles; and
5. a shadow only when it explains elevation or active state.

Use material by purpose, not by the color it happens to produce. Current
surfaces use thin material for floating ambient chrome, regular material for
controls and Settings cards, bar material for Settings footer chrome, and the
system window background for the regular window. Preserve that hierarchy.

When `accessibilityReduceTransparency` is true, replace translucent backgrounds
with an opaque semantic background. Do not merely increase opacity from 0.08 to
0.12 and declare victory.

## Color

- The selected profile accent identifies the active voice context.
- Red means destructive, failed, or stop; orange means active work where the
  existing presentation uses it; green means ready or saved; secondary means
  inactive or supporting information.
- Pair color with copy and a symbol or shape. Respect
  `accessibilityDifferentiateWithoutColor`.
- Prefer `primary`, `secondary`, `separator`, system backgrounds, and semantic
  status colors. Test custom tints in light, dark, and increased contrast.
- Never hard-code the apparent RGB value of a macOS system color.

## Typography

- Use standard SwiftUI text styles in Settings and conventional controls.
- Rounded system type gives compact voice and agent surfaces personality; keep
  long Markdown and detailed settings copy in the ordinary system design.
- Monospaced type is for executable paths, argument templates, identifiers, and
  code—not status prose.
- Establish hierarchy with no more levels than the surface needs: primary state,
  secondary explanation, compact section label. Avoid light font weights at
  small sizes.
- Prefer wrapping useful text over shrinking it into illegibility. Truncate only
  truly secondary, recoverable content.

## Symbols and controls

Use SF Symbols that match the adjacent text weight and the actual action.
Decorative symbols are accessibility-hidden; actionable symbols have labels,
help, and keyboard behavior. Prefer a labeled button unless the icon is
unambiguous in that exact context.

Use standard controls in Settings. Custom capsule and icon button styles belong
on the ambient panel where space and character justify them. Every custom
control still needs pressed, hover when useful, disabled, focus, and destructive
states.

Aim for the macOS default control size of 28 points; 20 points is the absolute
minimum target from Apple's accessibility guidance. Spacing counts as part of
click comfort, but invisible overlap between neighboring targets does not.

## Geometry

Use continuous rounded rectangles and circles consistently. A corner radius
expresses containment: the outer panel is softer than an inner card, which is
softer than a token. Do not assign a different radius to every view.

Respect safe visible frames across multiple displays, including negative
origins and smaller-than-preferred screens. Appearance is not slick if half of
the close button lives on a monitor that is no longer connected.

<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Apple platform guidance

Validated on 2026-09-05 against Apple documentation. The package deployment
target is macOS 15. Live `Package.swift` and compiler availability remain
authoritative because Apple guidance and SDK APIs evolve.

## Guidance applied here

- Use system components and familiar macOS behaviors before inventing custom
  interaction.
- Motion communicates status, feedback, instruction, and spatial continuity.
  Reduce automatic, repeating, spatial, scale, depth, and blur animation when
  Reduce Motion is enabled; fades are the preferred substitute.
- Materials communicate hierarchy. Select them by semantic purpose rather than
  apparent color, and maintain legibility across wallpaper, light/dark mode,
  contrast, and transparency preferences.
- Use semantic system colors. Custom colors need light, dark, and increased
  contrast behavior and cannot carry meaning alone.
- SF Symbols align with the system font and should match adjacent text weight.
- macOS uses SF Pro and does not support Dynamic Type. Still preserve readable
  sizes, hierarchy, wrapping, and system control fonts.
- macOS default controls are 28 by 28 points; 20 by 20 points is the recommended
  minimum.
- A non-activating `NSPanel` must remain a panel whose style mask and overrides
  prevent app activation. Custom material does not excuse focus theft.
- `PhaseAnimator` models discrete phases; `KeyframeAnimator` coordinates
  independently timed values and invokes its content closure each frame.

Do not use newer Liquid Glass or symbol features merely because current Apple
documentation highlights them. An API newer than macOS 15 needs an explicit
availability guard, a visually coherent fallback, and tests for both paths.

## Primary sources

- [Human Interface Guidelines: Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- [Human Interface Guidelines: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Human Interface Guidelines: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Human Interface Guidelines: Color](https://developer.apple.com/design/human-interface-guidelines/color)
- [Human Interface Guidelines: Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [Human Interface Guidelines: SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- [Controlling SwiftUI animation timing and movement](https://developer.apple.com/documentation/swiftui/controlling-the-timing-and-movements-of-your-animations)
- [`accessibilityReduceMotion`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)
- [`accessibilityReduceTransparency`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency)
- [`accessibilityDifferentiateWithoutColor`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilitydifferentiatewithoutcolor)
- [`NSWorkspace` accessibility display preferences](https://developer.apple.com/documentation/appkit/nsworkspace)
- [`NSVisualEffectView`](https://developer.apple.com/documentation/appkit/nsvisualeffectview)
- [`nonactivatingPanel`](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)

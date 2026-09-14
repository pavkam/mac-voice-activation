// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI

extension Design {
    /// Shadows and glows.
    ///
    /// Every shadow in the application is an accent glow rather than a neutral
    /// drop shadow, and cards carry none at all: depth on a card comes from its
    /// fill and its hairline. The single black shadow is the one under the app
    /// mark's waveform bars, where the bars sit on a saturated gradient and need
    /// separation that a glow cannot give.
    enum Glow {
        /// App mark. Pair with `Alpha.accentWashCard`-scale tint at 0.26.
        static let mark = (radius: CGFloat(10), y: CGFloat(4), alpha: 0.26)
        /// Agent provider mark.
        static let providerMark = (radius: CGFloat(7), y: CGFloat(3), alpha: 0.28)
        /// Conversation message avatar.
        static let miniMark = (radius: CGFloat(5), y: CGFloat(2), alpha: 0.18)
        /// Recording orb.
        static let orb = (radius: CGFloat(10), y: CGFloat(0), alpha: 0.46)
        /// Menu status dot.
        static let statusDot = (radius: CGFloat(4), y: CGFloat(0), alpha: 0.55)
        /// The app mark's waveform bars. The only black shadow in the app.
        static let markBars = (radius: CGFloat(2), y: CGFloat(1), alpha: 0.18)
        /// Lifts the action-feedback card off whatever it is floating over.
        static let feedbackCard = (radius: CGFloat(14), y: CGFloat(6), alpha: 0.22)
    }

    /// Vibrancy tiers.
    ///
    /// Blur is for floating surfaces only; nothing inside a window is blurred.
    /// Each tier is paired with a ground so it never renders as flat grey, and
    /// each has an opaque substitute under Reduce Transparency — raising a fill
    /// from 0.08 to 0.12 is not a substitute.
    enum Material {
        /// Menu panel, recording overlay capsule.
        static let floating = SwiftUI.Material.ultraThinMaterial
        /// The recording orb's glass disc.
        static let orb = SwiftUI.Material.thinMaterial
        /// Conversation panel, overlay cancel button.
        static let panel = SwiftUI.Material.regularMaterial
    }

    /// Accent washes.
    ///
    /// All three are diagonal and all three stay under 20% at their strongest.
    /// Full-bleed saturated gradients are not part of this application.
    enum Wash {
        /// The menu panel ground: accent, to clear, to a fainter accent.
        static func menu(_ accent: SwiftUI.Color) -> LinearGradient {
            LinearGradient(
                colors: [
                    accent.opacity(Alpha.accentWashMenu),
                    .clear,
                    accent.opacity(Alpha.accentWashFaint),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
        }

        /// The recording overlay capsule: the strongest wash in the application,
        /// because listening is the product and gets the visual budget.
        static func overlay(
            accent: SwiftUI.Color,
            highlight: SwiftUI.Color) -> LinearGradient {
            LinearGradient(
                colors: [
                    accent.opacity(Alpha.overlayWashLeading),
                    accent.opacity(Alpha.overlayWashMid),
                    highlight.opacity(Alpha.overlayWashTrailing),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
        }

        /// The conversation panel header ground.
        ///
        /// Radial rather than linear: the wash gathers behind the profile mark
        /// at the leading edge and falls away, so the header reads as lit by the
        /// profile rather than tinted by it.
        static func panelHeader(_ accent: SwiftUI.Color) -> RadialGradient {
            RadialGradient(
                colors: [accent.opacity(Alpha.panelHeaderWash), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 320)
        }

        /// The specular inset along a floating panel's top edge.
        static var panelSpecular: LinearGradient {
            LinearGradient(
                colors: [.white.opacity(Alpha.panelSpecular), .clear],
                startPoint: .top,
                endPoint: .bottom)
        }

        /// The overlay rim: a bright specular stop falling to the accent.
        static func overlayRim(accent: SwiftUI.Color) -> LinearGradient {
            LinearGradient(
                colors: [
                    .white.opacity(Alpha.hairlineBrightest),
                    accent.opacity(Alpha.accentBorder),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
        }
    }
}

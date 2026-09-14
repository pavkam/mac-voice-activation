// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit

/// Where the feedback surface sits.
///
/// It takes the recording overlay's place at the bottom of the active screen,
/// because it is the same interaction continuing: the user spoke there, and
/// the result of what they said belongs in the same spot rather than somewhere
/// new. Capture has ended by the time any of this shows, so the two never
/// occupy it at once.
///
/// The panel is a canvas rather than the shape the user sees. The card inside
/// hugs its own content, so a one-word acknowledgement does not sit in a box
/// sized for a sentence, and a long failure reason is not truncated to fit one.
enum ActionFeedbackOverlayLayout {
    /// Generous enough for the widest card the content can produce.
    static let canvasSize = NSSize(width: 460, height: 132)
    /// Matches the recording overlay, so the card settles where the orb was.
    static let bottomInset: CGFloat = 42

    static func frame(in visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.midX - (canvasSize.width / 2),
            y: visibleFrame.minY + bottomInset,
            width: canvasSize.width,
            height: canvasSize.height)
    }
}

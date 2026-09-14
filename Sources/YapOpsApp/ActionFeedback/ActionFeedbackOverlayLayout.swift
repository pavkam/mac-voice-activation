// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit

/// Where the feedback surface sits, and how big it is.
///
/// It takes the recording overlay's place at the bottom of the active screen,
/// because it is the same interaction continuing: the user spoke there, and
/// the result of what they said belongs in the same spot rather than somewhere
/// new. Capture has ended by the time any of this shows, so the two never
/// occupy it at once.
enum ActionFeedbackOverlayLayout {
    static let size = NSSize(width: 320, height: 64)
    /// A failure adds a line of explanation, so it needs the room for it.
    static let detailSize = NSSize(width: 380, height: 84)

    static func frame(showsDetail: Bool, in visibleFrame: NSRect) -> NSRect {
        let size = showsDetail ? detailSize : self.size
        return NSRect(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.minY + 42,
            width: size.width,
            height: size.height)
    }
}

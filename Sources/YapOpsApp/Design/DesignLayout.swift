// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import CoreGraphics

extension Design {
    /// Fixed window and element geometry.
    ///
    /// Every YapOps window is fixed-size: there is no resizable content area and
    /// there are no breakpoints, so these are hard numbers rather than
    /// preferences. Window sizes are still clamped to `visibleFrame` at
    /// placement time, because a panel half-way onto a disconnected display is
    /// not a layout.
    enum Layout {
        /// Menu panel width.
        static let menuWidth: CGFloat = 356
        /// Settings window width.
        static let settingsWidth: CGFloat = 720
        /// Settings height on the General tab.
        static let settingsHeightGeneral: CGFloat = 420
        /// Settings height on every other tab.
        static let settingsHeightTall: CGFloat = 660
        /// Profiles master list column.
        static let settingsSidebar: CGFloat = 218

        /// Menu status header disc.
        static let statusOrb: CGFloat = 44
        /// Status dot beside the header.
        static let statusDot: CGFloat = 8
        /// Profile row avatar.
        static let profileAvatar: CGFloat = 34
        /// Profile icon badge.
        static let iconBadge: CGFloat = 36
        /// Agent provider mark.
        static let providerMark: CGFloat = 44
        /// Conversation message avatar.
        static let miniMark: CGFloat = 27
        /// Recording orb once a transcript is visible.
        static let orbExpanded: CGFloat = 72
        /// Recording orb before any words arrive.
        static let orbIdle: CGFloat = 92
        /// Panel header glyph and button slot.
        /// Caps a feedback card's failure reason so a long message wraps
        /// to its second line instead of stretching the card off screen.
        static let feedbackDetailWidth: CGFloat = 268
        static let glyphSlot: CGFloat = 22
        /// Artifact preview.
        static let artifactPreview: CGFloat = 128
        /// Minimum comfortable hit target.
        static let hitTarget: CGFloat = 28
    }
}

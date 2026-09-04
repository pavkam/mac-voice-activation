// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit

enum AgentRunPanelLayout {
    static let expandedSize = NSSize(width: 620, height: 420)
    static let bottomInset: CGFloat = 42
    static let transitionDuration: TimeInterval = 0.42

    static func expandedFrame(in visibleFrame: NSRect) -> NSRect {
        let preferredX = visibleFrame.midX - (expandedSize.width / 2)
        let preferredY = visibleFrame.minY + bottomInset
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - expandedSize.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - expandedSize.height)
        return NSRect(
            x: min(max(preferredX, visibleFrame.minX), maximumX),
            y: min(max(preferredY, visibleFrame.minY), maximumY),
            width: expandedSize.width,
            height: expandedSize.height)
    }
}

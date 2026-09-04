// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit

struct AgentRunPanelPlacement {
    private var savedExpandedFrame: NSRect?

    mutating func reset() {
        savedExpandedFrame = nil
    }

    mutating func minimize(frame: NSRect, in visibleFrame: NSRect) -> NSRect {
        savedExpandedFrame = frame
        return AgentRunPanelLayout.compactFrame(minimizing: frame, in: visibleFrame)
    }

    mutating func restore(
        from compactFrame: NSRect,
        availableVisibleFrames: [NSRect],
        fallbackVisibleFrame: NSRect) -> NSRect
    {
        let sourceFrame = savedExpandedFrame ?? compactFrame
        savedExpandedFrame = nil
        let sourceCenter = NSPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        let targetVisibleFrame = availableVisibleFrames.first(where: {
            $0.contains(sourceCenter)
        }) ?? fallbackVisibleFrame
        return AgentRunPanelLayout.expandedFrame(
            restoring: sourceFrame,
            in: targetVisibleFrame)
    }
}

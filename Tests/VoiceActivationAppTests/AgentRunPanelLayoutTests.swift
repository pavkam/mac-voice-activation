// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import VoiceActivationApp

struct AgentRunPanelLayoutTests {
    @Test func expandedFrame_WhenScreenHasNegativeOrigin_IsBottomCentredAndClamped() {
        let visibleFrame = NSRect(x: -1_920, y: 24, width: 1_920, height: 1_056)

        let frame = AgentRunPanelLayout.expandedFrame(in: visibleFrame)

        #expect(frame.size == NSSize(width: 620, height: 420))
        #expect(frame.midX == visibleFrame.midX)
        #expect(frame.minY == visibleFrame.minY + 42)
        #expect(visibleFrame.contains(frame))
    }

    @Test func expandedFrame_WhenVisibleAreaIsSmaller_ClampsOriginWithoutChangingSize() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 500, height: 300)

        let frame = AgentRunPanelLayout.expandedFrame(in: visibleFrame)

        #expect(frame.size == NSSize(width: 620, height: 420))
        #expect(frame.origin == visibleFrame.origin)
    }

    @Test func compactFrame_WhenPanelMinimizes_MovesBelowTheMenuBarAtTopRight() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let expandedFrame = NSRect(x: 210, y: 80, width: 620, height: 420)

        let compactFrame = AgentRunPanelLayout.compactFrame(
            minimizing: expandedFrame,
            in: visibleFrame)

        #expect(compactFrame.size == NSSize(width: 372, height: 84))
        #expect(compactFrame.maxX == visibleFrame.maxX - 16)
        #expect(compactFrame.maxY == visibleFrame.maxY - 16)
        #expect(visibleFrame.contains(compactFrame))
    }

    @Test func restoredFrame_WhenCompactPanelWasMoved_FollowsItAndStaysVisible() {
        let visibleFrame = NSRect(x: -1_200, y: 24, width: 1_200, height: 776)
        let movedCompactFrame = NSRect(x: -390, y: 690, width: 372, height: 84)

        let frame = AgentRunPanelLayout.expandedFrame(
            restoring: movedCompactFrame,
            in: visibleFrame)

        #expect(frame == NSRect(x: -638, y: 354, width: 620, height: 420))
        #expect(visibleFrame.contains(frame))
    }

    @Test func placement_WhenMinimizedAndRestored_ReturnsToSavedExpandedLocation() {
        let originalScreen = NSRect(x: 0, y: 24, width: 1_440, height: 876)
        let otherScreen = NSRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
        let expandedFrame = NSRect(x: 280, y: 160, width: 620, height: 420)
        var placement = AgentRunPanelPlacement()

        let compactFrame = placement.minimize(
            frame: expandedFrame,
            in: originalScreen)
        let movedCompactFrame = NSRect(
            x: otherScreen.maxX - 388,
            y: otherScreen.maxY - 100,
            width: 372,
            height: 84)
        let restoredFrame = placement.restore(
            from: movedCompactFrame,
            availableVisibleFrames: [originalScreen, otherScreen],
            fallbackVisibleFrame: otherScreen)

        #expect(compactFrame.maxX == originalScreen.maxX - 16)
        #expect(restoredFrame == expandedFrame)
    }
}

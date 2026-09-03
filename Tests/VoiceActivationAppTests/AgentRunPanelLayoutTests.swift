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
}

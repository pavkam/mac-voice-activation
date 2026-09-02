import AppKit
import Testing
@testable import VoiceActivationApp

struct RecordingOverlayLayoutTests {
    @Test func frame_WhenStateChanges_UsesVisibleBoundsAndPreservesBottomCenter() {
        let visibleFrame = NSRect(x: 100, y: 80, width: 1_000, height: 700)

        let compact = RecordingOverlayLayout.frame(for: "", in: visibleFrame)
        let expanded = RecordingOverlayLayout.frame(for: "open calendar", in: visibleFrame)

        #expect(compact.size == NSSize(width: 126, height: 118))
        #expect(expanded.size == NSSize(width: 464, height: 118))
        #expect(compact.midX == visibleFrame.midX)
        #expect(expanded.midX == visibleFrame.midX)
        #expect(compact.minY == visibleFrame.minY + 42)
        #expect(expanded.minY == compact.minY)
    }

    @Test func shouldAnimate_WhenVisibleSurfaceChangesShape_ReturnsTrue() {
        #expect(RecordingOverlayLayout.shouldAnimate(
            from: "",
            to: "open calendar",
            panelIsVisible: true))
        #expect(RecordingOverlayLayout.shouldAnimate(
            from: "open calendar",
            to: "",
            panelIsVisible: true))
    }

    @Test func shouldAnimate_WhenPanelAppearsOrShapeIsUnchanged_ReturnsFalse() {
        #expect(!RecordingOverlayLayout.shouldAnimate(
            from: "",
            to: "",
            panelIsVisible: false))
        #expect(!RecordingOverlayLayout.shouldAnimate(
            from: "open",
            to: "open calendar",
            panelIsVisible: true))
    }

    @Test func shouldUpdateFrame_WhenVisibleTranscriptOnlyChangesText_ReturnsFalse() {
        #expect(!RecordingOverlayLayout.shouldUpdateFrame(
            from: "open",
            to: "open calendar",
            panelIsVisible: true))
        #expect(RecordingOverlayLayout.shouldUpdateFrame(
            from: "",
            to: "open calendar",
            panelIsVisible: true))
        #expect(RecordingOverlayLayout.shouldUpdateFrame(
            from: "",
            to: "",
            panelIsVisible: false))
    }
}

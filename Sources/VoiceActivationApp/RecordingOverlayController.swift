import AppKit
import SwiftUI
import VoiceActivationCore

@MainActor
final class RecordingOverlayController: RecordingOverlayDisplaying {
    private let model = RecordingOverlayModel()
    private let panel: NSPanel
    private var activeVisibleFrame: NSRect?

    var onCancel: (() -> Void)? {
        get { model.onCancel }
        set { model.onCancel = newValue }
    }

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: RecordingOverlayLayout.compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: RecordingOverlayView(model: model))
    }

    func show(transcript: String, accent: WakeProfileAccent) {
        let previousTranscript = model.transcript
        let panelWasVisible = panel.isVisible
        let shouldAnimate = RecordingOverlayLayout.shouldAnimate(
            from: previousTranscript,
            to: transcript,
            panelIsVisible: panelWasVisible)
        let shouldUpdateFrame = RecordingOverlayLayout.shouldUpdateFrame(
            from: previousTranscript,
            to: transcript,
            panelIsVisible: panelWasVisible)

        model.transcript = transcript
        model.accent = accent
        model.isRecording = true
        if !panelWasVisible {
            activeVisibleFrame = activeScreenVisibleFrame()
        }

        if shouldUpdateFrame {
            resizeAndPosition(for: transcript, animated: shouldAnimate)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        model.isRecording = false
        panel.orderOut(nil)
        activeVisibleFrame = nil
    }

    func takeAgentRunHandoff() -> RecordingOverlayHandoff? {
        guard panel.isVisible, let visibleFrame = activeVisibleFrame else { return nil }
        let handoff = RecordingOverlayHandoff(
            visibleScreenFrame: visibleFrame,
            sourceFrame: panel.frame)
        model.isRecording = false
        panel.orderOut(nil)
        activeVisibleFrame = nil
        return handoff
    }

    private func activeScreenVisibleFrame() -> NSRect? {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        return screen?.visibleFrame
    }

    private func resizeAndPosition(for transcript: String, animated: Bool) {
        guard let visibleFrame = activeVisibleFrame else { return }
        let frame = RecordingOverlayLayout.frame(for: transcript, in: visibleFrame)

        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = RecordingOverlayLayout.transitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }
}

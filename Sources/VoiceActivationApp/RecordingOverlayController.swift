import AppKit
import SwiftUI

@MainActor
final class RecordingOverlayController: RecordingOverlayDisplaying {
    private static let compactSize = NSSize(width: 150, height: 142)
    private static let expandedSize = NSSize(width: 488, height: 142)
    private let model = RecordingOverlayModel()
    private let panel: NSPanel
    private var activeVisibleFrame: NSRect?

    var onCancel: (() -> Void)? {
        get { model.onCancel }
        set { model.onCancel = newValue }
    }

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.compactSize),
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

    func show(transcript: String) {
        model.transcript = transcript
        model.isRecording = true
        if !panel.isVisible {
            activeVisibleFrame = activeScreenVisibleFrame()
        }
        resizeAndPosition(for: transcript)
        panel.orderFrontRegardless()
    }

    func hide() {
        model.isRecording = false
        panel.orderOut(nil)
        activeVisibleFrame = nil
    }

    private func activeScreenVisibleFrame() -> NSRect? {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        return screen?.visibleFrame
    }

    private func resizeAndPosition(for transcript: String) {
        guard let visibleFrame = activeVisibleFrame else { return }
        let size = transcript.isEmpty ? Self.compactSize : Self.expandedSize
        panel.setContentSize(size)

        let origin = NSPoint(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.minY + 42)
        panel.setFrameOrigin(origin)
    }
}

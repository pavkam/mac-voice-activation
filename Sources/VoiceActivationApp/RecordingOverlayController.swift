import AppKit
import SwiftUI

@MainActor
final class RecordingOverlayController: RecordingOverlayDisplaying {
    private static let panelSize = NSSize(width: 478, height: 190)
    private let model = RecordingOverlayModel()
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: RecordingOverlayView(model: model))
    }

    func show(transcript: String) {
        model.transcript = transcript
        model.isRecording = true
        if !panel.isVisible {
            positionOnActiveScreen()
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        model.isRecording = false
        panel.orderOut(nil)
    }

    private func positionOnActiveScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        let origin = NSPoint(
            x: visibleFrame.midX - (Self.panelSize.width / 2),
            y: visibleFrame.minY + 42)
        panel.setFrameOrigin(origin)
    }
}

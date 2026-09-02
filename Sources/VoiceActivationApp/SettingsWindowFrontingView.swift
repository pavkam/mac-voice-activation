import AppKit
import SwiftUI

struct SettingsWindowFrontingView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsWindowObserverView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SettingsWindowObserverView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard let window else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

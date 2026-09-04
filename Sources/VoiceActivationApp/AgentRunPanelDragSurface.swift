// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

struct AgentRunPanelDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> AgentRunPanelDragView {
        AgentRunPanelDragView()
    }

    func updateNSView(_ nsView: AgentRunPanelDragView, context: Context) {}
}

@MainActor
final class AgentRunPanelDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }
}

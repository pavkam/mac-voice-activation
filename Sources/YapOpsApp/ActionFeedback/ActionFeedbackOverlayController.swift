// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import YapOpsCore

/// Hosts the feedback surface in a non-activating panel.
///
/// It never takes focus and never accepts a click. The user is mid-sentence
/// with another app when a system action runs; a panel that stole the
/// foreground to say "Locked" would cost more than it told them.
@MainActor
final class ActionFeedbackOverlayController: ActionFeedbackDisplaying {
    private let model = ActionFeedbackOverlayModel()
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: ActionFeedbackOverlayLayout.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Nothing here is interactive, so clicks belong to whatever is behind.
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: ActionFeedbackOverlayView(model: model))
    }

    func show(_ presentation: ActionFeedbackPresentation) {
        YapOpsDiagnostics.shared.record(
            category: .ui,
            event: "action_feedback.shown",
            level: .debug,
            fields: [
                "tone": String(describing: presentation.tone),
                "has_detail": String(presentation.detail != nil),
            ])
        model.presentation = presentation
        if let visibleFrame = activeScreenVisibleFrame() {
            panel.setFrame(
                ActionFeedbackOverlayLayout.frame(
                    showsDetail: presentation.detail != nil,
                    in: visibleFrame),
                display: true)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        YapOpsDiagnostics.shared.record(
            category: .ui,
            event: "action_feedback.hidden",
            level: .debug,
            fields: ["was_visible": String(panel.isVisible)])
        model.presentation = nil
        panel.orderOut(nil)
    }

    private func activeScreenVisibleFrame() -> NSRect? {
        let mouseLocation = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first {
                NSMouseInRect(mouseLocation, $0.frame, false)
            } ?? NSScreen.main
        return screen?.visibleFrame
    }
}

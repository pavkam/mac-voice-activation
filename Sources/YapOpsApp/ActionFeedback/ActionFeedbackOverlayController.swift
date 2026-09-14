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
            contentRect: NSRect(origin: .zero, size: ActionFeedbackOverlayLayout.canvasSize),
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

    /// Shows one moment, growing out of the recording overlay when the surface
    /// is arriving for the first time.
    ///
    /// - Parameters:
    ///   - presentation: What to show.
    ///   - handoff: Where the recording overlay just was. Used only when the
    ///     panel is not already on screen: an outcome replacing a running
    ///     command keeps the frame it already settled into, because the card
    ///     is the same object changing state rather than a new one arriving.
    func show(_ presentation: ActionFeedbackPresentation, from handoff: RecordingOverlayHandoff?) {
        let wasVisible = panel.isVisible
        YapOpsDiagnostics.shared.record(
            category: .ui,
            event: "action_feedback.shown",
            level: .debug,
            fields: [
                "tone": String(describing: presentation.tone),
                "has_detail": String(presentation.detail != nil),
                "was_visible": String(wasVisible),
                "has_handoff": String(handoff != nil),
            ])
        model.presentation = presentation
        guard !wasVisible else { return }

        let visibleFrame =
            handoff?.visibleScreenFrame ?? activeScreenVisibleFrame()
            ?? NSRect(origin: .zero, size: ActionFeedbackOverlayLayout.canvasSize)
        let targetFrame = ActionFeedbackOverlayLayout.frame(in: visibleFrame)
        panel.setFrame(handoff?.sourceFrame ?? targetFrame, display: true)
        panel.orderFrontRegardless()
        animate(to: targetFrame)
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

    private func animate(to frame: NSRect) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ActionFeedbackOverlayMotion.morphDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
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

/// The one duration the panel frame and the card's own transition share, so
/// the window and its contents settle together rather than in sequence.
enum ActionFeedbackOverlayMotion {
    static let morphDuration: TimeInterval = 0.30
}

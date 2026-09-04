// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

@MainActor
final class AgentRunPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AgentRunPanelController: AgentRunPanelDisplaying {
    private let model = AgentRunPanelModel()
    private let panel: AgentRunPanel
    private var currentRunID: UUID?

    var onAction: ((AgentRunPanelAction) -> Void)? {
        get { model.onAction }
        set { model.onAction = newValue }
    }

    var panelForTesting: AgentRunPanel { panel }

    init() {
        panel = AgentRunPanel(
            contentRect: NSRect(origin: .zero, size: AgentRunPanelLayout.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: AgentRunPanelView(model: model))
    }

    func begin(_ snapshot: AgentRunSnapshot, from handoff: RecordingOverlayHandoff?) {
        currentRunID = snapshot.runID
        model.begin(snapshot)
        let visibleFrame = handoff?.visibleScreenFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: AgentRunPanelLayout.expandedSize)
        let targetFrame = AgentRunPanelLayout.expandedFrame(in: visibleFrame)
        panel.setFrame(handoff?.sourceFrame ?? targetFrame, display: true)
        panel.orderFrontRegardless()
        animate(to: targetFrame)
    }

    func update(_ snapshot: AgentRunSnapshot) {
        guard currentRunID == snapshot.runID else { return }
        model.update(snapshot)
    }

    func show(runID: UUID) {
        guard currentRunID == runID else { return }
        panel.orderFrontRegardless()
    }

    func hide(runID: UUID) {
        guard currentRunID == runID else { return }
        panel.orderOut(nil)
    }

    func minimize(runID: UUID) {
        guard currentRunID == runID, !model.isMinimized else { return }
        let targetFrame = AgentRunPanelLayout.compactFrame(
            minimizing: panel.frame,
            in: visibleFrame)
        withAnimation(.snappy(duration: AgentRunPanelLayout.transitionDuration)) {
            model.setMinimized(true)
        }
        animate(to: targetFrame)
    }

    func restore(runID: UUID) {
        guard currentRunID == runID, model.isMinimized else { return }
        let targetFrame = AgentRunPanelLayout.expandedFrame(
            restoring: panel.frame,
            in: visibleFrame)
        panel.orderFrontRegardless()
        withAnimation(.snappy(duration: AgentRunPanelLayout.transitionDuration)) {
            model.setMinimized(false)
        }
        animate(to: targetFrame)
    }

    private var visibleFrame: NSRect {
        panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: AgentRunPanelLayout.expandedSize)
    }

    private func animate(to frame: NSRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AgentRunPanelLayout.transitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }
}

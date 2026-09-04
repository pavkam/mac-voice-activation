// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import VoiceActivationCore

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
    private var placement = AgentRunPanelPlacement()

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
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: AgentRunPanelView(model: model))
    }

    func begin(_ snapshot: AgentRunSnapshot, from handoff: RecordingOverlayHandoff?) {
        VoiceActivationDiagnostics.shared.record(
            category: .ui,
            event: "agent_panel.window_beginning",
            fields: [
                "run_id": snapshot.runID.uuidString,
                "has_handoff": String(handoff != nil),
            ])
        currentRunID = snapshot.runID
        placement.reset()
        model.begin(snapshot)
        let visibleFrame =
            handoff?.visibleScreenFrame ?? NSScreen.main?.visibleFrame
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
        VoiceActivationDiagnostics.shared.record(
            category: .ui,
            event: "agent_panel.window_shown",
            fields: ["run_id": runID.uuidString])
    }

    func hide(runID: UUID) {
        guard currentRunID == runID else { return }
        panel.orderOut(nil)
        VoiceActivationDiagnostics.shared.record(
            category: .ui,
            event: "agent_panel.window_hidden",
            fields: ["run_id": runID.uuidString])
    }

    func minimize(runID: UUID) {
        guard currentRunID == runID, !model.isMinimized else { return }
        let targetFrame = placement.minimize(frame: panel.frame, in: visibleFrame)
        withAnimation(.snappy(duration: AgentRunPanelLayout.transitionDuration)) {
            model.setMinimized(true)
        }
        animate(to: targetFrame)
        VoiceActivationDiagnostics.shared.record(
            category: .ui,
            event: "agent_panel.window_minimized",
            fields: ["run_id": runID.uuidString])
    }

    func restore(runID: UUID) {
        guard currentRunID == runID, model.isMinimized else { return }
        let targetFrame = placement.restore(
            from: panel.frame,
            availableVisibleFrames: NSScreen.screens.map(\.visibleFrame),
            fallbackVisibleFrame: visibleFrame)
        panel.orderFrontRegardless()
        withAnimation(.snappy(duration: AgentRunPanelLayout.transitionDuration)) {
            model.setMinimized(false)
        }
        animate(to: targetFrame)
        VoiceActivationDiagnostics.shared.record(
            category: .ui,
            event: "agent_panel.window_restored",
            fields: ["run_id": runID.uuidString])
    }

    private var visibleFrame: NSRect {
        panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: AgentRunPanelLayout.expandedSize)
    }

    private func animate(to frame: NSRect) {
        VoiceActivationDiagnostics.shared.record(
            category: .ui,
            event: "agent_panel.window_animation_started",
            level: .debug,
            fields: [
                "target_width": String(describing: frame.width),
                "target_height": String(describing: frame.height),
            ])
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AgentRunPanelLayout.transitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }
}

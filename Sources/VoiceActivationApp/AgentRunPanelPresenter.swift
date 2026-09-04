// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import VoiceActivationCore

enum AgentRunPanelAction: Equatable {
    case cancel(runID: UUID)
    case endConversation(runID: UUID)
    case permission(runID: UUID, key: AgentPermissionKey, optionID: String)
    case copy(runID: UUID)
    case close(runID: UUID)
    case delete(runID: UUID)
    case minimize(runID: UUID)
    case restore(runID: UUID)
}

@MainActor
protocol AgentRunPanelDisplaying: AnyObject {
    var onAction: ((AgentRunPanelAction) -> Void)? { get set }

    func begin(_ snapshot: AgentRunSnapshot, from handoff: RecordingOverlayHandoff?)
    func update(_ snapshot: AgentRunSnapshot)
    func show(runID: UUID)
    func hide(runID: UUID)
    func minimize(runID: UUID)
    func restore(runID: UUID)
}

@MainActor
protocol AgentRunPasteboardWriting {
    func write(_ value: String)
}

@MainActor
struct SystemAgentRunPasteboardWriter: AgentRunPasteboardWriting {
    func write(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

@MainActor
final class AgentRunPanelPresenter {
    var onCancel: ((UUID) -> Void)?
    var onEndConversation: ((UUID) -> Void)?
    var onPermission: ((UUID, AgentPermissionKey, String) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?

    private let display: any AgentRunPanelDisplaying
    private let pasteboard: any AgentRunPasteboardWriting
    private let diagnostics: any VoiceActivationDiagnosticRecording
    private var snapshot: AgentRunSnapshot?
    private var cancelledRunID: UUID?
    private var endedRunID: UUID?
    private var isMinimized = false
    private var resolvedPermissions: Set<AgentPermissionKey> = []

    init(
        display: any AgentRunPanelDisplaying,
        pasteboard: any AgentRunPasteboardWriting = SystemAgentRunPasteboardWriter(),
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.display = display
        self.pasteboard = pasteboard
        self.diagnostics = diagnostics
        display.onAction = { [weak self] action in
            self?.handle(action)
        }
    }

    func begin(_ snapshot: AgentRunSnapshot, from handoff: RecordingOverlayHandoff?) {
        self.snapshot = snapshot
        cancelledRunID = nil
        endedRunID = nil
        isMinimized = false
        resolvedPermissions = []
        display.begin(snapshot, from: handoff)
        diagnostics.record(
            category: .ui,
            event: "agent_panel.began",
            fields: Self.snapshotFields(snapshot).merging([
                "has_overlay_handoff": String(handoff != nil)
            ]) { _, new in new })
    }

    func update(_ snapshot: AgentRunSnapshot) {
        guard self.snapshot?.runID == snapshot.runID else {
            diagnostics.record(
                category: .ui,
                event: "agent_panel.update_ignored",
                fields: [
                    "run_id": snapshot.runID.uuidString,
                    "reason": "stale_run",
                ])
            return
        }
        if snapshot.phase == .running, self.snapshot?.phase != .running {
            cancelledRunID = nil
        }
        resolvedPermissions.formIntersection(snapshot.permissions.lazy.map(\.key))
        self.snapshot = snapshot
        display.update(snapshot)
        diagnostics.record(
            category: .ui,
            event: "agent_panel.updated",
            fields: Self.snapshotFields(snapshot))
    }

    func show(runID: UUID) {
        guard snapshot?.runID == runID else { return }
        if isMinimized {
            isMinimized = false
            display.restore(runID: runID)
        } else {
            display.show(runID: runID)
        }
    }

    func hide(runID: UUID) {
        guard snapshot?.runID == runID else { return }
        display.hide(runID: runID)
    }

    func delete(runID: UUID) {
        handle(.delete(runID: runID))
    }

    private func handle(_ action: AgentRunPanelAction) {
        diagnostics.record(
            category: .ui,
            event: "agent_panel.action_received",
            fields: action.diagnosticFields)
        guard let snapshot else {
            recordIgnored(action, reason: "no_snapshot")
            return
        }
        switch action {
        case .cancel(let runID):
            guard snapshot.runID == runID,
                snapshot.phase == .running,
                cancelledRunID != runID
            else {
                recordIgnored(action, reason: "run_not_cancellable")
                return
            }
            cancelledRunID = runID
            display.hide(runID: runID)
            onCancel?(runID)
            recordApplied(action)
        case .endConversation(let runID):
            guard snapshot.runID == runID,
                !snapshot.phase.isTerminal,
                endedRunID != runID
            else {
                recordIgnored(action, reason: "conversation_not_active")
                return
            }
            endedRunID = runID
            onEndConversation?(runID)
            recordApplied(action)
        case .permission(let runID, let key, let optionID):
            guard snapshot.runID == runID,
                snapshot.phase == .running,
                !resolvedPermissions.contains(key),
                snapshot.permissions.contains(where: {
                    $0.key == key && !$0.isResolving
                })
            else {
                recordIgnored(action, reason: "permission_not_resolvable")
                return
            }
            resolvedPermissions.insert(key)
            onPermission?(runID, key, optionID)
            recordApplied(action)
        case .copy(let runID):
            guard snapshot.runID == runID, snapshot.phase.isTerminal else {
                recordIgnored(action, reason: "output_not_copyable")
                return
            }
            pasteboard.write(snapshot.copyText)
            recordApplied(
                action,
                fields: [
                    "copied_character_count": String(snapshot.copyText.count)
                ])
        case .close(let runID):
            guard snapshot.runID == runID, snapshot.phase.isTerminal else {
                recordIgnored(action, reason: "run_not_closable")
                return
            }
            display.hide(runID: runID)
            onClose?(runID)
            recordApplied(action)
        case .delete(let runID):
            guard snapshot.runID == runID, snapshot.phase.isTerminal else {
                recordIgnored(action, reason: "run_not_deletable")
                return
            }
            self.snapshot = nil
            isMinimized = false
            display.hide(runID: runID)
            onDelete?(runID)
            recordApplied(action)
        case .minimize(let runID):
            guard snapshot.runID == runID, !isMinimized else {
                recordIgnored(action, reason: "already_minimized_or_stale")
                return
            }
            isMinimized = true
            display.minimize(runID: runID)
            recordApplied(action)
        case .restore(let runID):
            guard snapshot.runID == runID, isMinimized else {
                recordIgnored(action, reason: "not_minimized_or_stale")
                return
            }
            isMinimized = false
            display.restore(runID: runID)
            recordApplied(action)
        }
    }

    private func recordApplied(
        _ action: AgentRunPanelAction,
        fields: [String: String] = [:]
    ) {
        diagnostics.record(
            category: .ui,
            event: "agent_panel.action_applied",
            fields: action.diagnosticFields.merging(fields) { _, new in new })
    }

    private func recordIgnored(_ action: AgentRunPanelAction, reason: String) {
        diagnostics.record(
            category: .ui,
            event: "agent_panel.action_ignored",
            level: .warning,
            fields: action.diagnosticFields.merging(["reason": reason]) { _, new in new })
    }

    private static func snapshotFields(_ snapshot: AgentRunSnapshot) -> [String: String] {
        [
            "run_id": snapshot.runID.uuidString,
            "phase": snapshot.phase.diagnosticName,
            "timeline_item_count": String(snapshot.timeline.count),
            "permission_count": String(snapshot.permissions.count),
            "notice_count": String(snapshot.notices.count),
            "elapsed_seconds": String(snapshot.elapsedSeconds),
        ]
    }
}

extension AgentRunPanelAction {
    fileprivate var diagnosticFields: [String: String] {
        [
            "action": diagnosticName,
            "run_id": runID.uuidString,
        ]
    }

    fileprivate var diagnosticName: String {
        switch self {
        case .cancel: "stop_turn"
        case .endConversation: "end_conversation"
        case .permission: "permission"
        case .copy: "copy"
        case .close: "close"
        case .delete: "delete"
        case .minimize: "minimize"
        case .restore: "restore"
        }
    }

    fileprivate var runID: UUID {
        switch self {
        case .cancel(let runID),
            .endConversation(let runID),
            .copy(let runID),
            .close(let runID),
            .delete(let runID),
            .minimize(let runID),
            .restore(let runID):
            runID
        case .permission(let runID, _, _):
            runID
        }
    }
}

extension AgentRunPhase {
    fileprivate var diagnosticName: String {
        switch self {
        case .listening: "listening"
        case .running: "running"
        case .cancelling: "cancelling"
        case .completed: "completed"
        case .failed: "failed"
        }
    }
}

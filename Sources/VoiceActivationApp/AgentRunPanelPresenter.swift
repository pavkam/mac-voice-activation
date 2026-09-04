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
    private var snapshot: AgentRunSnapshot?
    private var cancelledRunID: UUID?
    private var endedRunID: UUID?
    private var isMinimized = false
    private var resolvedPermissions: Set<AgentPermissionKey> = []

    init(
        display: any AgentRunPanelDisplaying,
        pasteboard: any AgentRunPasteboardWriting = SystemAgentRunPasteboardWriter())
    {
        self.display = display
        self.pasteboard = pasteboard
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
    }

    func update(_ snapshot: AgentRunSnapshot) {
        guard self.snapshot?.runID == snapshot.runID else { return }
        if snapshot.phase == .running, self.snapshot?.phase != .running {
            cancelledRunID = nil
        }
        resolvedPermissions.formIntersection(snapshot.permissions.lazy.map(\.key))
        self.snapshot = snapshot
        display.update(snapshot)
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
        guard let snapshot else { return }
        switch action {
        case let .cancel(runID):
            guard snapshot.runID == runID,
                  snapshot.phase == .running,
                  cancelledRunID != runID
            else { return }
            cancelledRunID = runID
            onCancel?(runID)
        case let .endConversation(runID):
            guard snapshot.runID == runID,
                  !snapshot.phase.isTerminal,
                  endedRunID != runID
            else { return }
            endedRunID = runID
            onEndConversation?(runID)
        case let .permission(runID, key, optionID):
            guard snapshot.runID == runID,
                  snapshot.phase == .running,
                  !resolvedPermissions.contains(key),
                  snapshot.permissions.contains(where: {
                      $0.key == key && !$0.isResolving
                  })
            else { return }
            resolvedPermissions.insert(key)
            onPermission?(runID, key, optionID)
        case let .copy(runID):
            guard snapshot.runID == runID, snapshot.phase.isTerminal else { return }
            pasteboard.write(snapshot.copyText)
        case let .close(runID):
            guard snapshot.runID == runID, snapshot.phase.isTerminal else { return }
            display.hide(runID: runID)
            onClose?(runID)
        case let .delete(runID):
            guard snapshot.runID == runID, snapshot.phase.isTerminal else { return }
            self.snapshot = nil
            isMinimized = false
            display.hide(runID: runID)
            onDelete?(runID)
        case let .minimize(runID):
            guard snapshot.runID == runID, !isMinimized else { return }
            isMinimized = true
            display.minimize(runID: runID)
        case let .restore(runID):
            guard snapshot.runID == runID, isMinimized else { return }
            isMinimized = false
            display.restore(runID: runID)
        }
    }
}

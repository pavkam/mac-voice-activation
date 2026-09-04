// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Observation
import VoiceActivationCore

@MainActor
@Observable
final class AgentRunPanelModel {
    var snapshot: AgentRunSnapshot?
    var isAutoFollowing = true
    private(set) var isMinimized = false
    var resolvingPermissions: Set<AgentPermissionKey> = []
    private(set) var expandedThinkingIDs: Set<UUID> = []
    private(set) var elapsedStartedAt: Date
    @ObservationIgnored var onAction: ((AgentRunPanelAction) -> Void)?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let diagnostics: any VoiceActivationDiagnosticRecording
    @ObservationIgnored private var isUserScrolling = false

    init(
        now: @escaping @MainActor () -> Date = Date.init,
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.now = now
        self.diagnostics = diagnostics
        elapsedStartedAt = now()
    }

    func begin(_ snapshot: AgentRunSnapshot) {
        elapsedStartedAt = now().addingTimeInterval(-TimeInterval(snapshot.elapsedSeconds))
        self.snapshot = snapshot
        isAutoFollowing = true
        isMinimized = false
        resolvingPermissions = []
        expandedThinkingIDs = []
        isUserScrolling = false
        diagnostics.record(
            category: .ui,
            event: "agent_panel.model_began",
            fields: ["run_id": snapshot.runID.uuidString])
    }

    func update(_ snapshot: AgentRunSnapshot) {
        guard let previousSnapshot = self.snapshot,
            previousSnapshot.runID == snapshot.runID
        else {
            diagnostics.record(
                category: .ui,
                event: "agent_panel.model_update_ignored",
                fields: [
                    "run_id": snapshot.runID.uuidString,
                    "reason": "stale_or_missing_snapshot",
                ])
            return
        }
        let previousThinking = previousSnapshot.timeline.compactMap {
            item -> AgentThinkingPresentation? in
            guard case .thinking(let thinking) = item else { return nil }
            return thinking
        }
        let currentThinking = snapshot.timeline.compactMap { item -> AgentThinkingPresentation? in
            guard case .thinking(let thinking) = item else { return nil }
            return thinking
        }
        let previouslySettled = Dictionary(
            uniqueKeysWithValues: previousThinking.map { ($0.id, $0.isSettled) })
        let newlySettledThinkingIDs = currentThinking.lazy.filter { thinking in
            thinking.isSettled && previouslySettled[thinking.id] != true
        }.map(\.id)
        expandedThinkingIDs.subtract(newlySettledThinkingIDs)
        expandedThinkingIDs.formIntersection(currentThinking.lazy.map(\.id))
        self.snapshot = snapshot
        resolvingPermissions = Set(snapshot.permissions.lazy.filter(\.isResolving).map(\.key))
        diagnostics.record(
            category: .ui,
            event: "agent_panel.model_updated",
            level: .debug,
            fields: [
                "run_id": snapshot.runID.uuidString,
                "timeline_item_count": String(snapshot.timeline.count),
                "thinking_group_count": String(currentThinking.count),
                "permission_count": String(snapshot.permissions.count),
            ])
    }

    func toggleThinkingDetails(thinkingID: UUID) {
        guard
            snapshot?.timeline.contains(where: { item in
                guard case .thinking(let thinking) = item else { return false }
                return thinking.id == thinkingID
            }) == true
        else {
            diagnostics.record(
                category: .ui,
                event: "agent_panel.thinking_toggle_ignored",
                fields: ["reason": "thinking_group_missing"])
            return
        }
        if !expandedThinkingIDs.insert(thinkingID).inserted {
            expandedThinkingIDs.remove(thinkingID)
        }
        diagnostics.record(
            category: .ui,
            event: "agent_panel.thinking_toggled",
            fields: [
                "thinking_id": thinkingID.uuidString,
                "expanded": String(expandedThinkingIDs.contains(thinkingID)),
            ])
    }

    func isThinkingExpanded(thinkingID: UUID) -> Bool {
        expandedThinkingIDs.contains(thinkingID)
    }

    func setMinimized(_ isMinimized: Bool) {
        guard snapshot != nil else { return }
        self.isMinimized = isMinimized
        diagnostics.record(
            category: .ui,
            event: "agent_panel.minimized_changed",
            fields: ["minimized": String(isMinimized)])
    }

    func selectPermission(_ permission: AgentPermissionPresentation, optionID: String) {
        guard let snapshot,
            !snapshot.phase.isTerminal,
            resolvingPermissions.insert(permission.key).inserted
        else {
            diagnostics.record(
                category: .ui,
                event: "agent_panel.permission_click_ignored",
                fields: ["reason": "terminal_or_already_resolving"])
            return
        }
        diagnostics.record(
            category: .ui,
            event: "agent_panel.permission_clicked",
            fields: ["run_id": snapshot.runID.uuidString])
        onAction?(
            .permission(
                runID: snapshot.runID,
                key: permission.key,
                optionID: optionID))
    }

    func beginUserScrolling(distanceFromBottom: CGFloat) {
        isUserScrolling = true
        updateAutoFollowing(distanceFromBottom: distanceFromBottom)
    }

    func endUserScrolling(distanceFromBottom: CGFloat) {
        guard isUserScrolling else { return }
        updateAutoFollowing(distanceFromBottom: distanceFromBottom)
        isUserScrolling = false
    }

    func updateScrollGeometry(distanceFromBottom: CGFloat) {
        guard isUserScrolling else { return }
        updateAutoFollowing(distanceFromBottom: distanceFromBottom)
    }

    private func updateAutoFollowing(distanceFromBottom: CGFloat) {
        let follows = distanceFromBottom <= 24
        guard follows != isAutoFollowing else { return }
        isAutoFollowing = follows
        diagnostics.record(
            category: .ui,
            event: "agent_panel.auto_follow_changed",
            fields: [
                "enabled": String(follows),
                "distance_from_bottom": String(describing: distanceFromBottom),
            ])
    }
}

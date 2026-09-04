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
    @ObservationIgnored private var isUserScrolling = false

    init(now: @escaping @MainActor () -> Date = Date.init) {
        self.now = now
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
    }

    func update(_ snapshot: AgentRunSnapshot) {
        guard let previousSnapshot = self.snapshot,
              previousSnapshot.runID == snapshot.runID
        else { return }
        let previousThinking = previousSnapshot.timeline.compactMap { item ->
            AgentThinkingPresentation? in
            guard case let .thinking(thinking) = item else { return nil }
            return thinking
        }
        let currentThinking = snapshot.timeline.compactMap { item ->
            AgentThinkingPresentation? in
            guard case let .thinking(thinking) = item else { return nil }
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
    }

    func toggleThinkingDetails(thinkingID: UUID) {
        guard snapshot?.timeline.contains(where: { item in
            guard case let .thinking(thinking) = item else { return false }
            return thinking.id == thinkingID
        }) == true else { return }
        if !expandedThinkingIDs.insert(thinkingID).inserted {
            expandedThinkingIDs.remove(thinkingID)
        }
    }

    func isThinkingExpanded(thinkingID: UUID) -> Bool {
        expandedThinkingIDs.contains(thinkingID)
    }

    func setMinimized(_ isMinimized: Bool) {
        guard snapshot != nil else { return }
        self.isMinimized = isMinimized
    }

    func selectPermission(_ permission: AgentPermissionPresentation, optionID: String) {
        guard let snapshot,
              !snapshot.phase.isTerminal,
              resolvingPermissions.insert(permission.key).inserted
        else { return }
        onAction?(.permission(
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
        isAutoFollowing = distanceFromBottom <= 24
    }
}

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
    var resolvingPermissions: Set<AgentPermissionKey> = []
    private(set) var expandedToolIDs: Set<String> = []
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
        resolvingPermissions = []
        expandedToolIDs = []
        isUserScrolling = false
    }

    func update(_ snapshot: AgentRunSnapshot) {
        guard let previousSnapshot = self.snapshot,
              previousSnapshot.runID == snapshot.runID
        else { return }
        let previouslyFinished = Dictionary(
            uniqueKeysWithValues: previousSnapshot.tools.map { ($0.id, $0.isFinished) })
        let newlyFinishedToolIDs = snapshot.tools.lazy.filter { tool in
            tool.isFinished && previouslyFinished[tool.id] != true
        }.map(\.id)
        expandedToolIDs.subtract(newlyFinishedToolIDs)
        expandedToolIDs.formIntersection(snapshot.tools.lazy.map(\.id))
        self.snapshot = snapshot
        resolvingPermissions = Set(snapshot.permissions.lazy.filter(\.isResolving).map(\.key))
    }

    func toggleToolDetails(toolID: String) {
        guard snapshot?.tools.contains(where: { $0.id == toolID }) == true else { return }
        if !expandedToolIDs.insert(toolID).inserted {
            expandedToolIDs.remove(toolID)
        }
    }

    func isToolExpanded(toolID: String) -> Bool {
        expandedToolIDs.contains(toolID)
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

import CoreGraphics
import Observation
import VoiceActivationCore

@MainActor
@Observable
final class AgentRunPanelModel {
    var snapshot: AgentRunSnapshot?
    var isAutoFollowing = true
    var resolvingPermissions: Set<AgentPermissionKey> = []
    private(set) var expandedToolIDs: Set<String> = []
    @ObservationIgnored var onAction: ((AgentRunPanelAction) -> Void)?

    func begin(_ snapshot: AgentRunSnapshot) {
        self.snapshot = snapshot
        isAutoFollowing = true
        resolvingPermissions = []
        expandedToolIDs = []
    }

    func update(_ snapshot: AgentRunSnapshot) {
        guard let previousSnapshot = self.snapshot,
              previousSnapshot.runID == snapshot.runID
        else { return }
        let previousStatuses = Dictionary(
            uniqueKeysWithValues: previousSnapshot.tools.map { ($0.id, $0.status) })
        let newlyFinishedToolIDs = snapshot.tools.lazy.filter { tool in
            tool.status.isTerminal && previousStatuses[tool.id]?.isTerminal != true
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

    func updateAutoFollowing(distanceFromBottom: CGFloat, userInitiated: Bool) {
        guard userInitiated else { return }
        isAutoFollowing = distanceFromBottom <= 24
    }
}

private extension AgentToolCallStatus? {
    var isTerminal: Bool {
        self == .completed || self == .failed
    }
}

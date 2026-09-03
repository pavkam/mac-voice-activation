import CoreGraphics
import Observation

@MainActor
@Observable
final class AgentRunPanelModel {
    var snapshot: AgentRunSnapshot?
    var isAutoFollowing = true
    var resolvingPermissions: Set<AgentPermissionKey> = []
    @ObservationIgnored var onAction: ((AgentRunPanelAction) -> Void)?

    func begin(_ snapshot: AgentRunSnapshot) {
        self.snapshot = snapshot
        isAutoFollowing = true
        resolvingPermissions = []
    }

    func update(_ snapshot: AgentRunSnapshot) {
        guard self.snapshot?.runID == snapshot.runID else { return }
        self.snapshot = snapshot
        resolvingPermissions = Set(snapshot.permissions.lazy.filter(\.isResolving).map(\.key))
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

    func updateAutoFollowing(distanceFromBottom: CGFloat) {
        isAutoFollowing = distanceFromBottom <= 24
    }
}

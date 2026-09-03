import AppKit
import VoiceActivationCore

enum AgentRunPanelAction: Equatable {
    case cancel(runID: UUID)
    case permission(runID: UUID, key: AgentPermissionKey, optionID: String)
    case copy(runID: UUID)
    case close(runID: UUID)
}

@MainActor
protocol AgentRunPanelDisplaying: AnyObject {
    var onAction: ((AgentRunPanelAction) -> Void)? { get set }

    func begin(_ snapshot: AgentRunSnapshot, from handoff: RecordingOverlayHandoff?)
    func update(_ snapshot: AgentRunSnapshot)
    func show(runID: UUID)
    func hide(runID: UUID)
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
    var onPermission: ((UUID, AgentPermissionKey, String) -> Void)?
    var onClose: ((UUID) -> Void)?

    private let display: any AgentRunPanelDisplaying
    private let pasteboard: any AgentRunPasteboardWriting
    private var snapshot: AgentRunSnapshot?
    private var cancelledRunID: UUID?
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
        resolvedPermissions = []
        display.begin(snapshot, from: handoff)
    }

    func update(_ snapshot: AgentRunSnapshot) {
        guard self.snapshot?.runID == snapshot.runID else { return }
        self.snapshot = snapshot
        display.update(snapshot)
    }

    func show(runID: UUID) {
        guard snapshot?.runID == runID else { return }
        display.show(runID: runID)
    }

    func hide(runID: UUID) {
        guard snapshot?.runID == runID else { return }
        display.hide(runID: runID)
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
        }
    }
}

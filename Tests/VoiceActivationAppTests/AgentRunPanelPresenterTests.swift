import AppKit
import SwiftUI
import Testing
@testable import VoiceActivationApp
@testable import VoiceActivationCore

@MainActor
private final class AgentRunPanelDisplaySpy: AgentRunPanelDisplaying {
    var onAction: ((AgentRunPanelAction) -> Void)?
    private(set) var began: [(AgentRunSnapshot, RecordingOverlayHandoff?)] = []
    private(set) var updates: [AgentRunSnapshot] = []
    private(set) var shown: [UUID] = []
    private(set) var hidden: [UUID] = []

    func begin(_ snapshot: AgentRunSnapshot, from handoff: RecordingOverlayHandoff?) {
        began.append((snapshot, handoff))
    }

    func update(_ snapshot: AgentRunSnapshot) { updates.append(snapshot) }
    func show(runID: UUID) { shown.append(runID) }
    func hide(runID: UUID) { hidden.append(runID) }
}

@MainActor
private final class AgentRunPasteboardSpy: AgentRunPasteboardWriting {
    private(set) var values: [String] = []
    func write(_ value: String) { values.append(value) }
}

struct AgentRunPanelPresenterTests {
    @MainActor @Test func actions_WhenRepeatedOrStale_AreRunScopedAndExactlyOnce() throws {
        let display = AgentRunPanelDisplaySpy()
        let pasteboard = AgentRunPasteboardSpy()
        let presenter = AgentRunPanelPresenter(display: display, pasteboard: pasteboard)
        let runID = UUID()
        let snapshot = runningSnapshot(runID: runID)
        var cancellations: [UUID] = []
        presenter.onCancel = { cancellations.append($0) }
        presenter.begin(snapshot, from: nil)

        display.onAction?(.cancel(runID: runID))
        display.onAction?(.cancel(runID: runID))
        display.onAction?(.cancel(runID: UUID()))

        #expect(cancellations == [runID])
    }

    @MainActor @Test func terminalActions_WhenInvoked_CopyAndHideRetainedRun() throws {
        let display = AgentRunPanelDisplaySpy()
        let pasteboard = AgentRunPasteboardSpy()
        let presenter = AgentRunPanelPresenter(display: display, pasteboard: pasteboard)
        let runID = UUID()
        var snapshot = runningSnapshot(runID: runID)
        snapshot = AgentRunSnapshot(
            runID: snapshot.runID,
            profileID: snapshot.profileID,
            accent: snapshot.accent,
            prompt: snapshot.prompt,
            providerName: snapshot.providerName,
            phase: .completed(.endTurn),
            output: "Finished",
            diagnostics: "",
            plan: [],
            tools: [],
            permissions: [],
            notices: [],
            elapsedSeconds: 2,
            evictedToolCount: 0,
            ignoredToolUpdateCount: 0)
        presenter.begin(snapshot, from: nil)

        display.onAction?(.copy(runID: runID))
        display.onAction?(.close(runID: runID))
        presenter.show(runID: runID)

        #expect(pasteboard.values == [snapshot.copyText])
        #expect(display.hidden == [runID])
        #expect(display.shown == [runID])
    }

    @MainActor @Test func panel_WhenConstructed_IsFloatingAndCannotBecomeKeyOrMain() {
        let controller = AgentRunPanelController()
        let panel = controller.panelForTesting

        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.stationary))
        #expect(!panel.hasShadow)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    @MainActor @Test func view_WhenRendered_FillsTheExpandedPanel() throws {
        let model = AgentRunPanelModel()
        model.begin(runningSnapshot(runID: UUID()))
        let renderer = ImageRenderer(content: AgentRunPanelView(model: model))
        renderer.proposedSize = ProposedViewSize(width: 620, height: 420)

        let image = try #require(renderer.cgImage)

        #expect(image.width == 620)
        #expect(image.height == 420)
    }

    @MainActor @Test func model_WhenUserMovesAwayFromBottom_DisablesAndReenablesFollow() {
        let model = AgentRunPanelModel()

        model.updateAutoFollowing(distanceFromBottom: 25)
        #expect(!model.isAutoFollowing)
        model.updateAutoFollowing(distanceFromBottom: 24)
        #expect(model.isAutoFollowing)
    }

    @MainActor
    private func runningSnapshot(runID: UUID) -> AgentRunSnapshot {
        AgentRunSnapshot(
            runID: runID,
            profileID: UUID(),
            accent: .purple,
            prompt: "Do the work",
            providerName: "Codex",
            phase: .running,
            output: "",
            diagnostics: "",
            plan: [],
            tools: [],
            permissions: [],
            notices: [],
            elapsedSeconds: 0,
            evictedToolCount: 0,
            ignoredToolUpdateCount: 0)
    }
}

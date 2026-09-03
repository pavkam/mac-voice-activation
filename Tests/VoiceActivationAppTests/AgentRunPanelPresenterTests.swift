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

    @MainActor @Test func endConversation_WhenRepeatedOrStale_IsRunScopedAndExactlyOnce() {
        let display = AgentRunPanelDisplaySpy()
        let presenter = AgentRunPanelPresenter(
            display: display,
            pasteboard: AgentRunPasteboardSpy())
        let runID = UUID()
        var endedRuns: [UUID] = []
        presenter.onEndConversation = { endedRuns.append($0) }
        presenter.begin(runningSnapshot(runID: runID), from: nil)

        display.onAction?(.endConversation(runID: runID))
        display.onAction?(.endConversation(runID: runID))
        display.onAction?(.endConversation(runID: UUID()))

        #expect(endedRuns == [runID])
    }

    @MainActor @Test func cancel_WhenNextTurnStarts_CanBeInvokedAgainForSameConversation() {
        let display = AgentRunPanelDisplaySpy()
        let presenter = AgentRunPanelPresenter(
            display: display,
            pasteboard: AgentRunPasteboardSpy())
        let runID = UUID()
        var cancellations: [UUID] = []
        presenter.onCancel = { cancellations.append($0) }
        var snapshot = runningSnapshot(runID: runID)
        presenter.begin(snapshot, from: nil)
        display.onAction?(.cancel(runID: runID))

        snapshot = replacingPhase(.cancelling, in: snapshot)
        presenter.update(snapshot)
        snapshot = replacingPhase(.listening, in: snapshot)
        presenter.update(snapshot)
        snapshot = replacingPhase(.running, in: snapshot)
        presenter.update(snapshot)
        display.onAction?(.cancel(runID: runID))

        #expect(cancellations == [runID, runID])
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
            voiceInput: "",
            output: "Finished",
            timeline: [
                .message(AgentMessagePresentation(
                    id: UUID(),
                    messageID: "final",
                    kind: .response,
                    text: "Finished")),
            ],
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

    @MainActor @Test func model_WhenUserScrollsAwayFromBottom_DisablesAndReenablesFollow() {
        let model = AgentRunPanelModel()

        model.updateAutoFollowing(distanceFromBottom: 25, userInitiated: true)
        #expect(!model.isAutoFollowing)
        model.updateAutoFollowing(distanceFromBottom: 24, userInitiated: true)
        #expect(model.isAutoFollowing)
    }

    @MainActor @Test func model_WhenContentGrowsWithoutUserScroll_KeepsFollowingEnabled() {
        let model = AgentRunPanelModel()

        model.updateAutoFollowing(distanceFromBottom: 200, userInitiated: false)

        #expect(model.isAutoFollowing)
    }

    @MainActor @Test func toolDetails_WhenToolCompletes_CollapsesButCanBeExpandedAgain() {
        let model = AgentRunPanelModel()
        let runID = UUID()
        model.begin(toolSnapshot(runID: runID, status: .inProgress))

        model.toggleToolDetails(toolID: "tool-1")
        #expect(model.isToolExpanded(toolID: "tool-1"))

        model.update(toolSnapshot(runID: runID, status: .completed))
        #expect(!model.isToolExpanded(toolID: "tool-1"))

        model.toggleToolDetails(toolID: "tool-1")
        #expect(model.isToolExpanded(toolID: "tool-1"))
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
            voiceInput: "",
            output: "",
            timeline: [],
            diagnostics: "",
            plan: [],
            tools: [],
            permissions: [],
            notices: [],
            elapsedSeconds: 0,
            evictedToolCount: 0,
            ignoredToolUpdateCount: 0)
    }

    @MainActor
    private func toolSnapshot(
        runID: UUID,
        status: AgentToolCallStatus) -> AgentRunSnapshot
    {
        let tool = AgentToolPresentation(
            id: "tool-1",
            title: "Read Package.swift",
            kind: .read,
            status: status)
        return AgentRunSnapshot(
            runID: runID,
            profileID: UUID(),
            accent: .purple,
            prompt: "Inspect",
            providerName: "Codex",
            phase: .running,
            voiceInput: "",
            output: "",
            timeline: [.tool(tool)],
            diagnostics: "",
            plan: [],
            tools: [tool],
            permissions: [],
            notices: [],
            elapsedSeconds: 0,
            evictedToolCount: 0,
            ignoredToolUpdateCount: 0)
    }

    @MainActor
    private func replacingPhase(
        _ phase: AgentRunPhase,
        in snapshot: AgentRunSnapshot) -> AgentRunSnapshot
    {
        AgentRunSnapshot(
            runID: snapshot.runID,
            profileID: snapshot.profileID,
            accent: snapshot.accent,
            prompt: snapshot.prompt,
            providerName: snapshot.providerName,
            phase: phase,
            voiceInput: snapshot.voiceInput,
            output: snapshot.output,
            timeline: snapshot.timeline,
            diagnostics: snapshot.diagnostics,
            plan: snapshot.plan,
            tools: snapshot.tools,
            permissions: snapshot.permissions,
            notices: snapshot.notices,
            elapsedSeconds: snapshot.elapsedSeconds,
            evictedToolCount: snapshot.evictedToolCount,
            ignoredToolUpdateCount: snapshot.ignoredToolUpdateCount)
    }
}

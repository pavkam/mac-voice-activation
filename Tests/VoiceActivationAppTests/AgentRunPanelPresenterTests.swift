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

    @MainActor @Test func permission_WhenRequestKeyIsReusedAfterRemoval_CanBeResolvedAgain() {
        let display = AgentRunPanelDisplaySpy()
        let presenter = AgentRunPanelPresenter(
            display: display,
            pasteboard: AgentRunPasteboardSpy())
        let runID = UUID()
        let key = AgentPermissionKey(
            turnToken: AgentTurnToken(),
            requestID: .string("permission"))
        let permission = AgentPermissionPresentation(
            key: key,
            toolTitle: "Edit file",
            options: [
                AgentPermissionOption(id: "once", label: "Allow once", kind: .allowOnce),
            ],
            isResolving: false)
        var resolutions: [AgentPermissionKey] = []
        presenter.onPermission = { _, key, _ in resolutions.append(key) }
        var snapshot = replacingPermissions(
            [permission],
            in: runningSnapshot(runID: runID))
        presenter.begin(snapshot, from: nil)
        display.onAction?(.permission(runID: runID, key: key, optionID: "once"))

        snapshot = replacingPermissions([], in: snapshot)
        presenter.update(snapshot)
        snapshot = replacingPermissions([permission], in: snapshot)
        presenter.update(snapshot)
        display.onAction?(.permission(runID: runID, key: key, optionID: "once"))

        #expect(resolutions == [key, key])
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

    @MainActor @Test func delete_WhenRunIsTerminal_HidesAndForgetsItExactlyOnce() {
        let display = AgentRunPanelDisplaySpy()
        let presenter = AgentRunPanelPresenter(
            display: display,
            pasteboard: AgentRunPasteboardSpy())
        let runID = UUID()
        var deletedRuns: [UUID] = []
        presenter.onDelete = { deletedRuns.append($0) }
        presenter.begin(
            replacingPhase(.completed(.endTurn), in: runningSnapshot(runID: runID)),
            from: nil)

        display.onAction?(.delete(runID: runID))
        display.onAction?(.delete(runID: runID))
        display.onAction?(.delete(runID: UUID()))
        presenter.show(runID: runID)

        #expect(display.hidden == [runID])
        #expect(display.shown.isEmpty)
        #expect(deletedRuns == [runID])
    }

    @MainActor @Test func delete_WhenRunIsActive_DoesNothing() {
        let display = AgentRunPanelDisplaySpy()
        let presenter = AgentRunPanelPresenter(
            display: display,
            pasteboard: AgentRunPasteboardSpy())
        let runID = UUID()
        var deletedRuns: [UUID] = []
        presenter.onDelete = { deletedRuns.append($0) }
        presenter.begin(runningSnapshot(runID: runID), from: nil)

        display.onAction?(.delete(runID: runID))

        #expect(display.hidden.isEmpty)
        #expect(deletedRuns.isEmpty)
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

        model.beginUserScrolling(distanceFromBottom: 0)
        model.updateScrollGeometry(distanceFromBottom: 25)
        #expect(!model.isAutoFollowing)
        model.updateScrollGeometry(distanceFromBottom: 24)
        #expect(model.isAutoFollowing)
        model.endUserScrolling(distanceFromBottom: 24)
    }

    @MainActor @Test func model_WhenContentGrowsWithoutUserScroll_KeepsFollowingEnabled() {
        let model = AgentRunPanelModel()

        model.updateScrollGeometry(distanceFromBottom: 200)

        #expect(model.isAutoFollowing)
    }

    @MainActor @Test func model_WhenProgrammaticScrollReturnsToBottom_DoesNotOverrideUserChoice() {
        let model = AgentRunPanelModel()
        model.beginUserScrolling(distanceFromBottom: 0)
        model.updateScrollGeometry(distanceFromBottom: 100)
        model.endUserScrolling(distanceFromBottom: 100)

        model.updateScrollGeometry(distanceFromBottom: 0)

        #expect(!model.isAutoFollowing)
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

    @MainActor @Test func toolDetails_WhenTurnSettlesWithoutFinalStatus_Collapses() {
        let model = AgentRunPanelModel()
        let runID = UUID()
        model.begin(toolSnapshot(runID: runID, status: .inProgress))
        model.toggleToolDetails(toolID: "tool-1")

        model.update(toolSnapshot(runID: runID, status: .inProgress, isSettled: true))

        #expect(!model.isToolExpanded(toolID: "tool-1"))
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
        status: AgentToolCallStatus,
        isSettled: Bool = false) -> AgentRunSnapshot
    {
        let tool = AgentToolPresentation(
            id: "tool-1",
            title: "Read Package.swift",
            kind: .read,
            status: status,
            isSettled: isSettled)
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

    @MainActor
    private func replacingPermissions(
        _ permissions: [AgentPermissionPresentation],
        in snapshot: AgentRunSnapshot) -> AgentRunSnapshot
    {
        AgentRunSnapshot(
            runID: snapshot.runID,
            profileID: snapshot.profileID,
            accent: snapshot.accent,
            prompt: snapshot.prompt,
            providerName: snapshot.providerName,
            phase: snapshot.phase,
            voiceInput: snapshot.voiceInput,
            output: snapshot.output,
            timeline: snapshot.timeline,
            diagnostics: snapshot.diagnostics,
            plan: snapshot.plan,
            tools: snapshot.tools,
            permissions: permissions,
            notices: snapshot.notices,
            elapsedSeconds: snapshot.elapsedSeconds,
            evictedToolCount: snapshot.evictedToolCount,
            ignoredToolUpdateCount: snapshot.ignoredToolUpdateCount)
    }
}

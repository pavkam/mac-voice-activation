import Foundation
import Testing
@testable import VoiceActivationApp
@testable import VoiceActivationCore

@Suite(.serialized)
struct AgentRunPresentationTests {
    @MainActor @Test func receive_WhenEventsStream_ReducesOrderedVisibleState() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let profile = try makeAgentProfile()
        let runID = UUID()

        presentation.start(runID: runID, profile: profile, prompt: "Explain this code")
        presentation.receive(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer", text: "Hello "))
        presentation.receive(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer", text: "world"))
        presentation.receive(
            runID: runID,
            event: .plan([
                AgentPlanEntry(content: "Inspect", priority: .high, status: .inProgress),
            ]))
        presentation.receive(
            runID: runID,
            event: .toolCall(AgentToolCall(
                id: "tool-1",
                title: "Read file",
                kind: .read,
                status: .inProgress)))

        let snapshot = try #require(presentation.snapshot)
        #expect(snapshot.runID == runID)
        #expect(snapshot.providerName == "Codex")
        #expect(snapshot.prompt == "Explain this code")
        #expect(snapshot.output == "Hello world")
        #expect(snapshot.plan.map(\.content) == ["Inspect"])
        #expect(snapshot.tools.map(\.id) == ["tool-1"])
    }

    @MainActor @Test func receive_WhenMoreThanThirtyTwoToolsArrive_EvictsOldest() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Work")

        for index in 0..<33 {
            presentation.receive(
                runID: runID,
                event: .toolCall(AgentToolCall(id: "tool-\(index)", title: "Tool \(index)")))
        }

        let snapshot = try #require(presentation.snapshot)
        #expect(snapshot.tools.count == 32)
        #expect(snapshot.tools.first?.id == "tool-1")
        #expect(snapshot.evictedToolCount == 1)
    }

    @MainActor @Test func receive_WhenRunIDIsStale_DoesNotMutateCurrentRun() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let currentRunID = UUID()
        presentation.start(
            runID: currentRunID,
            profile: try makeAgentProfile(),
            prompt: "Current")

        presentation.receive(
            runID: UUID(),
            event: .agentMessageDelta(messageID: nil, text: "stale"))

        #expect(presentation.snapshot?.output == "")
    }

    @MainActor @Test func permission_WhenResolved_DisablesExactlyThatRequest() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        let request = AgentPermissionRequest(
            turnToken: AgentTurnToken(),
            requestID: .string("permission"),
            toolCall: AgentToolCallUpdate(id: "tool", title: "Edit file"),
            options: [
                AgentPermissionOption(id: "once", label: "Allow once", kind: .allowOnce),
            ])
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Edit")
        presentation.receive(runID: runID, event: .permissionRequested(request))

        let key = AgentPermissionKey(
            turnToken: request.turnToken,
            requestID: request.requestID)
        #expect(presentation.beginPermissionResolution(runID: runID, key: key))
        #expect(!presentation.beginPermissionResolution(runID: runID, key: key))
        #expect(presentation.snapshot?.permissions.first?.isResolving == true)
    }

    @MainActor @Test func complete_WhenResultArrives_PublishesTerminalPhase() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Finish")

        presentation.complete(runID: runID, result: AgentRunResult(stopReason: .maxTokens))

        #expect(presentation.snapshot?.phase == .completed(.maxTokens))
    }

    @MainActor @Test func receive_WhenMultibyteOutputExceedsLimit_RetainsValidBoundedSuffix() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Stream")

        presentation.receive(
            runID: runID,
            event: .agentMessageDelta(
                messageID: "large",
                text: String(repeating: "🧪", count: 140_000)))

        let output = try #require(presentation.snapshot?.output)
        #expect(output.utf8.count <= AgentRunPresentation.maximumOutputBytes)
        #expect(output.hasPrefix("… earlier output omitted …"))
        #expect(output.hasSuffix("🧪"))
    }

    @MainActor @Test func receive_WhenDiagnosticsExceedLimit_RetainsNewestBoundedText() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Stream")

        presentation.receive(
            runID: runID,
            event: .diagnostic("old-marker" + String(repeating: "n", count: 20_000)))

        let diagnostics = try #require(presentation.snapshot?.diagnostics)
        #expect(diagnostics.utf8.count <= AgentRunPresentation.maximumDiagnosticBytes)
        #expect(!diagnostics.contains("old-marker"))
        #expect(diagnostics.hasPrefix("… earlier diagnostics omitted …"))
    }

    @MainActor @Test func receive_WhenTokensBurst_CoalescesPublications() async throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        var publications: [AgentRunSnapshot] = []
        presentation.onPublication = { publications.append($0) }
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Stream")

        for _ in 0..<100 {
            presentation.receive(
                runID: runID,
                event: .agentMessageDelta(messageID: "message", text: "x"))
        }
        #expect(publications.count == 1)

        try await Task.sleep(for: .milliseconds(100))

        #expect(publications.count == 2)
        #expect(publications.last?.output == String(repeating: "x", count: 100))
    }

    private func makeAgentProfile() throws -> WakeProfile {
        try WakeProfile(
            wakePhrase: "computer",
            action: .agent(AgentHarnessConfiguration(
                preset: .codex,
                displayName: "Codex",
                executablePath: "/usr/bin/env",
                arguments: ["codex-acp"],
                workingDirectory: "/tmp",
                permissionPolicy: .ask)),
            accent: .purple)
    }
}

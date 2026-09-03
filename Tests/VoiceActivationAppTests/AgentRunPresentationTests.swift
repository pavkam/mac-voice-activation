import Foundation
import Testing
@testable import VoiceActivationApp
@testable import VoiceActivationCore

@Suite(.serialized)
struct AgentRunPresentationTests {
    @MainActor @Test func discard_WhenRunMatches_ClearsStateAndIgnoresLateEvents() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(
            runID: runID,
            profile: try makeAgentProfile(),
            prompt: "Inspect")
        presentation.complete(
            runID: runID,
            result: AgentRunResult(stopReason: .endTurn))

        presentation.discard(runID: runID)
        presentation.receive(
            runID: runID,
            event: .agentMessageDelta(messageID: "late", text: "Do not restore"))

        #expect(presentation.snapshot == nil)
    }

    @MainActor @Test func discard_WhenRunIsStale_PreservesCurrentConversation() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(
            runID: runID,
            profile: try makeAgentProfile(),
            prompt: "Inspect")

        presentation.discard(runID: UUID())

        #expect(presentation.snapshot?.runID == runID)
    }

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

    @MainActor @Test func receive_WhenTextContinuesAfterTool_PreservesVisibleWireOrder() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(
            runID: runID,
            profile: try makeAgentProfile(),
            prompt: "Inspect")

        presentation.receive(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer-1", text: "I’ll inspect it."))
        presentation.receive(
            runID: runID,
            event: .toolCall(AgentToolCall(
                id: "tool-1",
                title: "Read Package.swift",
                kind: .read,
                status: .inProgress)))
        presentation.receive(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer-2", text: "\n\nFound the issue."))

        let timeline = try #require(presentation.snapshot?.timeline)
        #expect(timeline.count == 3)
        guard case let .message(before) = timeline[0],
              case let .tool(tool) = timeline[1],
              case let .message(after) = timeline[2]
        else {
            Issue.record("Expected message, tool, message timeline order")
            return
        }
        #expect(before.text == "I’ll inspect it.")
        #expect(tool.id == "tool-1")
        #expect(after.text == "\n\nFound the issue.")
    }

    @MainActor @Test func receive_WhenAdjacentMessageChunksArrive_CoalescesOneTimelineBlock()
        throws
    {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Explain")

        presentation.receive(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer", text: "Hello "))
        presentation.receive(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer", text: "**world**"))

        let timeline = try #require(presentation.snapshot?.timeline)
        #expect(timeline.count == 1)
        guard case let .message(message) = timeline[0] else {
            Issue.record("Expected one coalesced message")
            return
        }
        #expect(message.text == "Hello **world**")
    }

    @MainActor @Test func receive_WhenThoughtAndResponseStream_CopiesOnlyResponseOutput() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Explain")

        presentation.receive(
            runID: runID,
            event: .thoughtDelta(messageID: "thought", text: "Checking the parser"))
        presentation.receive(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer", text: "The parser is correct."))

        let snapshot = try #require(presentation.snapshot)
        #expect(snapshot.output == "The parser is correct.")
        #expect(snapshot.copyText.contains("The parser is correct."))
        #expect(!snapshot.copyText.contains("Checking the parser"))
    }

    @MainActor @Test func receive_WhenToolCompletes_UpdatesItsOriginalTimelinePosition() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Inspect")
        presentation.receive(
            runID: runID,
            event: .toolCall(AgentToolCall(
                id: "tool-1",
                title: "Reading",
                kind: .read,
                status: .inProgress)))

        presentation.receive(
            runID: runID,
            event: .toolCallUpdate(AgentToolCallUpdate(
                id: "tool-1",
                title: "Read Package.swift",
                status: .completed)))

        let timeline = try #require(presentation.snapshot?.timeline)
        #expect(timeline.count == 1)
        guard case let .tool(tool) = timeline[0] else {
            Issue.record("Expected the original tool timeline item")
            return
        }
        #expect(tool.title == "Read Package.swift")
        #expect(tool.status == .completed)
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

    @MainActor @Test func permission_WhenResolved_CollapsesExactlyThatRequestImmediately() throws {
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
        #expect(presentation.snapshot?.permissions.isEmpty == true)
    }

    @MainActor @Test func complete_WhenResultArrives_PublishesTerminalPhase() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Finish")

        presentation.complete(runID: runID, result: AgentRunResult(stopReason: .maxTokens))

        #expect(presentation.snapshot?.phase == .completed(.maxTokens))
    }

    @MainActor @Test func completeTurn_WhenProviderOmitsFinalToolStatus_SettlesTool() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Inspect")
        presentation.receive(
            runID: runID,
            event: .toolCall(AgentToolCall(
                id: "tool-1",
                title: "Read Package.swift",
                kind: .read,
                status: .inProgress)))

        presentation.completeTurn(
            runID: runID,
            result: AgentRunResult(stopReason: .endTurn))

        let tool = try #require(presentation.snapshot?.tools.first)
        #expect(tool.isFinished)
        #expect(!tool.isWorking)
    }

    @MainActor @Test func fail_WhenProviderOmitsFinalToolStatus_SettlesTool() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Inspect")
        presentation.receive(
            runID: runID,
            event: .toolCall(AgentToolCall(
                id: "tool-1",
                title: "Read Package.swift",
                kind: .read,
                status: .inProgress)))

        presentation.fail(runID: runID, message: "Connection closed")

        let tool = try #require(presentation.snapshot?.tools.first)
        #expect(tool.isFinished)
        #expect(!tool.isWorking)
    }

    @MainActor @Test func conversation_WhenFollowUpRuns_PreservesChronologicalMessages() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(
            runID: runID,
            profile: try makeAgentProfile(),
            prompt: "Inspect the parser")
        presentation.receive(
            runID: runID,
            event: .agentMessageDelta(messageID: "first-answer", text: "It is recursive."))
        presentation.completeTurn(
            runID: runID,
            result: AgentRunResult(stopReason: .endTurn))

        presentation.submitFollowUp(runID: runID, prompt: "Show me where")
        presentation.beginTurn(runID: runID)
        presentation.receive(
            runID: runID,
            event: .agentMessageDelta(messageID: "second-answer", text: "In `Parser.swift`."))
        presentation.completeTurn(
            runID: runID,
            result: AgentRunResult(stopReason: .endTurn))

        let snapshot = try #require(presentation.snapshot)
        #expect(snapshot.phase == .listening)
        #expect(snapshot.voiceInput.isEmpty)
        #expect(snapshot.output == "It is recursive.\n\nIn `Parser.swift`.")
        #expect(snapshot.timeline.count == 3)
        guard case let .message(firstAnswer) = snapshot.timeline[0],
              case let .userMessage(followUp) = snapshot.timeline[1],
              case let .message(secondAnswer) = snapshot.timeline[2]
        else {
            Issue.record("Expected answer, follow-up, answer in chronological order")
            return
        }
        #expect(firstAnswer.text == "It is recursive.")
        #expect(followUp.text == "Show me where")
        #expect(secondAnswer.text == "In `Parser.swift`.")
    }

    @MainActor @Test func conversation_WhenSeveralFollowUpsWereQueued_SeparatesEveryResponse()
        throws
    {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "First")
        presentation.receive(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer-1", text: "One"))
        presentation.submitFollowUp(runID: runID, prompt: "Second")
        presentation.submitFollowUp(runID: runID, prompt: "Third")

        presentation.beginTurn(runID: runID)
        presentation.receive(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer-2", text: "Two"))
        presentation.completeTurn(
            runID: runID,
            result: AgentRunResult(stopReason: .endTurn))
        presentation.beginTurn(runID: runID)
        presentation.receive(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer-3", text: "Three"))

        #expect(presentation.snapshot?.output == "One\n\nTwo\n\nThree")
    }

    @MainActor @Test func beginTurn_WhenPreviousTurnHadAPlan_ClearsStalePlan() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Inspect")
        presentation.receive(
            runID: runID,
            event: .plan([
                AgentPlanEntry(content: "Read files", priority: .high, status: .completed),
            ]))
        presentation.completeTurn(
            runID: runID,
            result: AgentRunResult(stopReason: .endTurn))
        presentation.submitFollowUp(runID: runID, prompt: "Now fix it")

        presentation.beginTurn(runID: runID)

        #expect(presentation.snapshot?.plan.isEmpty == true)
    }

    @MainActor @Test func voiceInput_WhenConversationListens_PublishesLiveTranscript() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Start")
        presentation.completeTurn(
            runID: runID,
            result: AgentRunResult(stopReason: .endTurn))

        presentation.updateVoiceInput(runID: runID, transcript: "and also")

        #expect(presentation.snapshot?.voiceInput == "and also")
        #expect(presentation.snapshot?.phase == .listening)
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

    @MainActor @Test func receive_WhenVisibleTimelineTextIsLarge_RetainsBoundedValidSuffix()
        throws
    {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Stream")

        presentation.receive(
            runID: runID,
            event: .agentMessageDelta(
                messageID: "large",
                text: "old-marker" + String(repeating: "🧪", count: 30_000)))

        let timeline = try #require(presentation.snapshot?.timeline)
        guard case .some(.omitted) = timeline.first,
              case let .some(.message(message)) = timeline.last
        else {
            Issue.record("Expected an omission marker followed by retained response text")
            return
        }
        #expect(message.text.utf8.count <= AgentRunPresentation.maximumTimelineTextBytes)
        #expect(!message.text.contains("old-marker"))
        #expect(message.text.hasSuffix("🧪"))
    }

    @MainActor @Test func receive_WhenTimelineHasManyMessages_BoundsVisibleItemCount() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Stream")

        for index in 0...AgentRunPresentation.maximumTimelineItems {
            presentation.receive(
                runID: runID,
                event: .agentMessageDelta(messageID: "message-\(index)", text: "x"))
        }

        let timeline = try #require(presentation.snapshot?.timeline)
        #expect(timeline.count == AgentRunPresentation.maximumTimelineItems)
        guard case .some(.omitted) = timeline.first else {
            Issue.record("Expected an omission marker at the start of the bounded timeline")
            return
        }
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

    @MainActor @Test func notice_WhenManyArrive_RetainsNewestVisibleNotices() throws {
        let presentation = AgentRunPresentation(startsElapsedTimer: false)
        let runID = UUID()
        presentation.start(runID: runID, profile: try makeAgentProfile(), prompt: "Work")

        for index in 0...16 {
            presentation.receiveNotice(runID: runID, message: "Notice \(index)")
        }
        presentation.receiveNotice(runID: runID, message: "Notice 16")

        let notices = try #require(presentation.snapshot?.notices)
        #expect(notices.count == 16)
        #expect(notices.first == "Notice 1")
        #expect(notices.last == "Notice 16")
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

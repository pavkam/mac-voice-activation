// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore


extension ACPClientConnectionTests {
    @Test func connect_WhenAgentSupportsV1_InitializesAndCreatesSessionWithAmbientAuth() async throws {
        let transport = FakeACPTransport()
        let configuration = try makeConfiguration()
        let connectionTask = Task {
            try await ACPClientConnection.connect(
                transport: transport,
                configuration: configuration)
        }

        let initialize = await transport.nextSentMessage()
        #expect(initialize == .request(
            id: .integer(1),
            method: "initialize",
            params: .object([
                "protocolVersion": .integer(1),
                "clientCapabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("voice-activation"),
                    "title": .string("Voice Activation"),
                    "version": .string("0.1.0"),
                ]),
            ])))
        try await transport.feed(initializeResponse(
            authMethods: [
                authMethod(id: "provider-login", name: "Provider login"),
            ]))

        let newSession = await transport.nextSentMessage()
        #expect(newSession == .request(
            id: .integer(2),
            method: "session/new",
            params: .object([
                "cwd": .string("/tmp/project"),
                "mcpServers": .array([]),
            ])))
        try await transport.feed(.response(
            id: .integer(2),
            result: .object(["sessionId": .string("session-1")])))

        let connection = try await connectionTask.value
        let outbound = await transport.allSentMessages()
        let rawFrames = await transport.allRawFrames()
        #expect(outbound.count == 2)
        #expect(!outbound.contains { message in
            guard case let .request(_, method, _) = message else { return false }
            return method == "authenticate"
        })
        #expect(rawFrames.allSatisfy { frame in
            frame.last == 0x0A && !frame.dropLast().contains(0x0A)
        })
        #expect(await transport.observedOutputCallCount() == 1)

        await connection.close()
    }

    @Test func connect_WhenAgentSelectsDifferentProtocol_ClosesAndThrows() async throws {
        let transport = FakeACPTransport()
        let connectionTask = Task {
            try await ACPClientConnection.connect(
                transport: transport,
                configuration: try makeConfiguration())
        }
        _ = await transport.nextSentMessage()
        try await transport.feed(initializeResponse(protocolVersion: 2))

        await #expect(throws: ACPClientError.incompatibleProtocol(selected: 2)) {
            try await connectionTask.value
        }
        #expect(await transport.observedTerminationCount() == 1)
        #expect(await transport.allSentMessages().count == 1)
    }

    @Test func connect_WhenSessionRequiresAuthentication_ThrowsWithAdvertisedMethods() async throws {
        let transport = FakeACPTransport()
        let oversizedName = String(repeating: "private-provider-login-", count: 40)
        let connectionTask = Task {
            try await ACPClientConnection.connect(
                transport: transport,
                configuration: try makeConfiguration())
        }
        _ = await transport.nextSentMessage()
        try await transport.feed(initializeResponse(authMethods: [
            authMethod(id: "api-key", name: "API key"),
            authMethod(id: "chatgpt", name: oversizedName),
        ]))
        _ = await transport.nextSentMessage()
        try await transport.feed(.errorResponse(
            id: .integer(2),
            error: ACPJSONRPCError(
                code: -32_000,
                message: "Authentication required",
                data: .object(["secret": .string("must-not-surface")]))))

        do {
            _ = try await connectionTask.value
            Issue.record("Expected authentication to be required")
        } catch let error as ACPClientError {
            guard case let .authenticationRequired(methods) = error else {
                Issue.record("Expected authenticationRequired, got \(error)")
                return
            }
            #expect(methods.first == "API key")
            #expect(methods.count == 2)
            #expect(methods[1].utf8.count <= ACPClientConnection.maximumDiagnosticBytes)
            #expect(!error.localizedDescription.contains("must-not-surface"))
            #expect(error.localizedDescription.contains("provider CLI"))
        }
        #expect(await transport.observedTerminationCount() == 1)
        #expect(await transport.allSentMessages().count == 2)
    }

    @Test func connect_WhenSessionIdentifierExceedsOpaqueBound_ClosesAndThrows() async throws {
        let transport = FakeACPTransport()
        let connectionTask = Task {
            try await ACPClientConnection.connect(
                transport: transport,
                configuration: try makeConfiguration())
        }
        _ = await transport.nextSentMessage()
        try await transport.feed(initializeResponse())
        _ = await transport.nextSentMessage()
        let oversized = String(
            repeating: "s",
            count: ACPEventDecoder.maximumOpaqueIdentifierBytes + 1)

        try await transport.feed(.response(
            id: .integer(2),
            result: .object(["sessionId": .string(oversized)])))

        await #expect(throws: ACPClientError.malformedResponse(
            "sessionId exceeds the opaque identifier limit.")) {
            try await connectionTask.value
        }
        #expect(await transport.observedTerminationCount() == 1)
    }

    @Test func prompt_WhenUpdatesArriveBeforeResponse_PublishesThemInWireOrder() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Inspect the project", recorder: recorder)

        #expect(await recorder.nextEvent() == .connected(
            agentName: "Test Agent",
            sessionID: "session-1"))
        let promptRequest = await transport.nextSentMessage()
        guard case let .request(id, method, .object(parameters)) = promptRequest,
              case let .array(blocks) = parameters["prompt"],
              blocks.count == 2,
              case let .object(instructionBlock) = blocks[0],
              case let .string(instruction) = instructionBlock["text"],
              case let .object(requestBlock) = blocks[1],
              case let .string(requestText) = requestBlock["text"]
        else {
            Issue.record("Expected a Markdown instruction followed by the spoken request")
            return
        }
        #expect(id == .integer(3))
        #expect(method == "session/prompt")
        #expect(parameters["sessionId"] == .string("session-1"))
        #expect(instructionBlock["type"] == .string("text"))
        #expect(instruction.localizedCaseInsensitiveContains("Markdown"))
        #expect(instruction.localizedCaseInsensitiveContains("user-facing"))
        #expect(instruction.localizedCaseInsensitiveContains("progress narration"))
        #expect(instruction.localizedCaseInsensitiveContains("one short sentence"))
        #expect(instruction.localizedCaseInsensitiveContains("individual tool calls"))
        #expect(instruction.localizedCaseInsensitiveContains("final answer"))
        #expect(requestBlock["type"] == .string("text"))
        #expect(requestText == "Inspect the project")
        try await transport.feed(sessionUpdate(
            .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("First"),
                ]),
            ])))
        try await transport.feed(sessionUpdate(
            .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string(" second"),
                ]),
            ])))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))

        #expect(await recorder.nextEvent() == .agentMessageDelta(messageID: nil, text: "First"))
        #expect(await recorder.nextEvent() == .agentMessageDelta(messageID: nil, text: " second"))
        #expect(try await promptTask.value == AgentRunResult(stopReason: .endTurn))
        await connection.close()
    }

    @Test func prompt_WhenUpdateBelongsToAnotherSession_IgnoresItsContent() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Keep sessions isolated", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()

        try await transport.feed(sessionUpdate(
            .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("Content from another session"),
                ]),
            ]),
            sessionID: "different-session"))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))

        #expect(await recorder.nextEvent() == .diagnostic(
            "Ignored ACP update for a different session."))
        #expect(try await promptTask.value == AgentRunResult(stopReason: .endTurn))
        #expect(await recorder.recordedEvents().isEmpty)
        await connection.close()
    }

    @Test func prompt_WhenCustomProfileHasSystemPrompt_SendsItBeforeTheSpokenRequest() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(
            transport: transport,
            preset: .custom,
            systemPrompt: "Use short answers and call out destructive actions.")
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Inspect the project", recorder: recorder)
        _ = await recorder.nextEvent()

        guard case let .request(_, "session/prompt", .object(parameters)) =
            await transport.nextSentMessage(),
            case let .array(blocks) = parameters["prompt"],
            blocks.count == 2,
            case let .object(instructionBlock) = blocks[0],
            case let .string(instruction) = instructionBlock["text"],
            case let .object(requestBlock) = blocks[1],
            case let .string(requestText) = requestBlock["text"]
        else {
            Issue.record("Expected a system instruction followed by the spoken request")
            return
        }
        #expect(instruction.contains("Use short answers and call out destructive actions."))
        #expect(instruction.localizedCaseInsensitiveContains("Markdown"))
        #expect(requestText == "Inspect the project")

        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await promptTask.value
        await connection.close()
    }

    @Test func prompt_WhenCodexHasDeveloperInstructions_DoesNotDuplicateThemAsUserText()
        async throws
    {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(
            transport: transport,
            preset: .codex,
            systemPrompt: "Use short answers and call out destructive actions.")
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Inspect the project", recorder: recorder)
        _ = await recorder.nextEvent()

        guard case let .request(_, "session/prompt", .object(parameters)) =
            await transport.nextSentMessage(),
            case let .array(blocks) = parameters["prompt"],
            blocks.count == 2,
            case let .object(instructionBlock) = blocks[0],
            case let .string(instruction) = instructionBlock["text"]
        else {
            Issue.record("Expected the Markdown instruction followed by the spoken request")
            return
        }
        #expect(!instruction.contains("Use short answers and call out destructive actions."))
        #expect(instruction.localizedCaseInsensitiveContains("Markdown"))

        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await promptTask.value
        await connection.close()
    }

    @Test func prompt_WhenEventDeliveryIsDelayed_FlushesWireOrderBeforeReturning() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let recorder = AgentEventRecorder()
        let gate = AgentEventGate()
        let completed = AgentEventSignal()
        let promptTask = Task {
            let result = try await connection.prompt("Wait for delivery") { event in
                if event == .agentMessageDelta(messageID: nil, text: "First") {
                    await gate.pause()
                }
                await recorder.record(event)
            }
            await completed.signal()
            return result
        }
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()

        try await transport.feed(sessionUpdate(.object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object([
                "type": .string("text"),
                "text": .string("First"),
            ]),
        ])))
        await gate.waitUntilEntered()
        try await transport.feed(sessionUpdate(.object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object([
                "type": .string("text"),
                "text": .string(" second"),
            ]),
        ])))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        try await transport.feed(.request(
            id: .string("response-barrier"),
            method: "unsupported/barrier",
            params: nil))

        #expect(await transport.nextSentMessage() == .errorResponse(
            id: .string("response-barrier"),
            error: ACPJSONRPCError(code: -32_601, message: "Method not found")))
        #expect(await completed.observedSignal() == false)

        await gate.open()
        #expect(await recorder.nextEvent() == .agentMessageDelta(messageID: nil, text: "First"))
        #expect(await recorder.nextEvent() == .agentMessageDelta(
            messageID: nil,
            text: " second"))
        #expect(try await promptTask.value == AgentRunResult(stopReason: .endTurn))
        await connection.close()
    }

    @Test func prompt_WhenControlOnlyDeliveryOverflows_DrainsPrefixThenFailsAndCloses()
        async throws
    {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let recorder = AgentEventRecorder()
        let gate = AgentEventGate()
        let promptTask = Task {
            try await connection.prompt("Overflow") { event in
                if case .connected = event {
                    await gate.pause()
                }
                await recorder.record(event)
            }
        }
        await gate.waitUntilEntered()
        _ = await transport.nextSentMessage()

        for index in 0..<AgentRunEventDelivery.maximumPendingEntries {
            try await transport.feed(sessionUpdate(.object([
                "sessionUpdate": .string("current_mode_update"),
                "currentModeId": .string("mode-\(index)"),
            ])))
        }
        while await connection.eventDeliverySnapshotForTesting()?.pendingEntryCount
            != AgentRunEventDelivery.maximumPendingEntries
        {
            await Task.yield()
        }
        try await transport.feed(sessionUpdate(.object([
            "sessionUpdate": .string("current_mode_update"),
            "currentModeId": .string("mode-\(AgentRunEventDelivery.maximumPendingEntries)"),
        ])))
        while await connection.eventDeliverySnapshotForTesting()?.state != .draining {
            await Task.yield()
        }
        await gate.open()

        await #expect(throws: ACPClientError.eventDeliveryOverflow) {
            try await promptTask.value
        }
        let expected = [
            AgentRunEvent.connected(agentName: "Test Agent", sessionID: "session-1"),
        ] + (0..<AgentRunEventDelivery.maximumPendingEntries).map { index in
            AgentRunEvent.metadata(
                kind: "current_mode_update",
                summary: "Current mode: mode-\(index)")
        }
        #expect(await recorder.recordedEvents() == expected)
        #expect(await transport.observedTerminationCount() == 1)
    }

    @Test func prompt_WhenJSONRPCErrorArrives_ThrowsUserSafeError() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Fail safely", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        try await transport.feed(.errorResponse(
            id: .integer(3),
            error: ACPJSONRPCError(
                code: -32_603,
                message: "Provider refused request.\n" + String(repeating: "x", count: 1_000),
                data: .object(["private": .string("secret payload")]))))

        do {
            _ = try await promptTask.value
            Issue.record("Expected the prompt to fail")
        } catch let error as ACPClientError {
            guard case let .remoteError(code, message) = error else {
                Issue.record("Expected remoteError, got \(error)")
                return
            }
            #expect(code == -32_603)
            #expect(message.utf8.count <= ACPClientConnection.maximumDiagnosticBytes)
            #expect(!message.contains("\n"))
            #expect(!error.localizedDescription.contains("secret payload"))
        }
        await connection.close()
    }

    @Test func prompt_WhenTextExceedsEightKiB_RejectsBeforeWriting() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let recorder = AgentEventRecorder()
        let originalMessageCount = await transport.allSentMessages().count

        await #expect(throws: ACPClientError.promptTooLarge(maximumBytes: 8_192)) {
            try await connection.prompt(
                String(repeating: "a", count: 8_193),
                onEvent: { event in await recorder.record(event) })
        }

        #expect(await transport.allSentMessages().count == originalMessageCount)
        await connection.close()
    }

    @Test func prompt_WhenEveryStableStopReasonArrives_ReturnsCompleteResult() async throws {
        let fixtures: [(String, AgentStopReason)] = [
            ("end_turn", .endTurn),
            ("max_tokens", .maxTokens),
            ("max_turn_requests", .maxTurnRequests),
            ("refusal", .refusal),
            ("cancelled", .cancelled),
        ]

        for (wireReason, expectedReason) in fixtures {
            let transport = FakeACPTransport()
            let connection = try await establishConnection(transport: transport)
            let recorder = AgentEventRecorder()
            let promptTask = prompt(connection, text: "Reason", recorder: recorder)
            _ = await recorder.nextEvent()
            _ = await transport.nextSentMessage()
            try await transport.feed(promptResponse(id: 3, stopReason: wireReason))

            #expect(try await promptTask.value == AgentRunResult(stopReason: expectedReason))
            await connection.close()
        }
    }

}

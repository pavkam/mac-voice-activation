import Foundation
import Testing
@testable import VoiceActivationCore

private actor AgentEventRecorder {
    private var events: [AgentRunEvent] = []
    private var waiters: [CheckedContinuation<AgentRunEvent, Never>] = []

    func record(_ event: AgentRunEvent) {
        if waiters.isEmpty {
            events.append(event)
        } else {
            waiters.removeFirst().resume(returning: event)
        }
    }

    func nextEvent() async -> AgentRunEvent {
        if !events.isEmpty {
            return events.removeFirst()
        }

        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor AgentEventGate {
    private var entered = false
    private var isOpen = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else {
            return
        }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor AgentEventSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isSignalled else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func observedSignal() -> Bool {
        isSignalled
    }
}

@Suite(.serialized)
struct ACPClientConnectionTests {
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

    @Test func prompt_WhenUpdatesArriveBeforeResponse_PublishesThemInWireOrder() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Inspect the project", recorder: recorder)

        #expect(await recorder.nextEvent() == .connected(
            agentName: "Test Agent",
            sessionID: "session-1"))
        let promptRequest = await transport.nextSentMessage()
        #expect(promptRequest == .request(
            id: .integer(3),
            method: "session/prompt",
            params: .object([
                "sessionId": .string("session-1"),
                "prompt": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Inspect the project"),
                    ]),
                ]),
            ])))
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

    @Test func permission_WhenPolicyAllowsOnce_SelectsOnlyOfferedAllowOnceOption() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport, policy: .allowOnce)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Edit", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        let requestID = ACPRequestID.integer(9_007_199_254_740_993)
        try await transport.feed(permissionRequest(
            id: requestID,
            options: [
                permissionOption(id: "always", name: "Always", kind: "allow_always"),
                permissionOption(id: "once", name: "Once", kind: "allow_once"),
            ]))

        #expect(await transport.nextSentMessage() == permissionSelection(
            id: requestID,
            optionID: "once"))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await promptTask.value
        await connection.close()
    }

    @Test func permission_WhenAllowOnceIsUnavailable_SelectsOfferedAllowAlwaysOption() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport, policy: .allowOnce)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Edit", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        try await transport.feed(permissionRequest(
            id: .integer(41),
            options: [permissionOption(
                id: "always",
                name: "Always",
                kind: "allow_always")]))

        #expect(await transport.nextSentMessage() == permissionSelection(
            id: .integer(41),
            optionID: "always"))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await promptTask.value
        await connection.close()
    }

    @Test func permission_WhenPolicyAsks_WaitsForExplicitResolutionWithoutBlockingInput() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport, policy: .ask)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Edit", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        let requestID = ACPRequestID.string("permission-17")
        try await transport.feed(permissionRequest(
            id: requestID,
            options: [permissionOption(id: "once", name: "Once", kind: "allow_once")]))

        guard case let .permissionRequested(permission) = await recorder.nextEvent() else {
            Issue.record("Expected a permission event")
            return
        }
        #expect(permission.requestID == requestID)
        #expect(permission.options == [
            AgentPermissionOption(id: "once", label: "Once", kind: .allowOnce),
        ])
        #expect(await transport.allSentMessages().count == 3)

        try await transport.feed(sessionUpdate(.object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object([
                "type": .string("text"),
                "text": .string("Still receiving"),
            ]),
        ])))
        #expect(await recorder.nextEvent() == .agentMessageDelta(
            messageID: nil,
            text: "Still receiving"))

        await connection.resolvePermission(
            turnToken: permission.turnToken,
            requestID: requestID,
            optionID: "once")
        #expect(await transport.nextSentMessage() == permissionSelection(
            id: requestID,
            optionID: "once"))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await promptTask.value
        await connection.close()
    }

    @Test func permission_WhenAskResolutionWasNotOffered_ReturnsCancelled() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport, policy: .ask)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Edit", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        let requestID = ACPRequestID.string("permission-18")
        try await transport.feed(permissionRequest(
            id: requestID,
            options: [permissionOption(id: "once", name: "Once", kind: "allow_once")]))
        guard case let .permissionRequested(permission) = await recorder.nextEvent() else {
            Issue.record("Expected a permission event")
            return
        }

        await connection.resolvePermission(
            turnToken: permission.turnToken,
            requestID: requestID,
            optionID: "invented")

        #expect(await transport.nextSentMessage() == permissionCancellation(id: requestID))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await promptTask.value
        await connection.close()
    }

    @Test func permission_WhenWireIDIsReusedOnANewTurn_IgnoresStaleTurnResolution() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport, policy: .ask)
        let firstRecorder = AgentEventRecorder()
        let firstPrompt = prompt(connection, text: "First turn", recorder: firstRecorder)
        _ = await firstRecorder.nextEvent()
        _ = await transport.nextSentMessage()
        let reusedID = ACPRequestID.string("reused-permission")
        try await transport.feed(permissionRequest(
            id: reusedID,
            options: [permissionOption(id: "once", name: "Once", kind: "allow_once")]))
        guard case let .permissionRequested(firstPermission) = await firstRecorder.nextEvent() else {
            Issue.record("Expected the first permission event")
            return
        }

        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await firstPrompt.value

        let secondRecorder = AgentEventRecorder()
        let secondPrompt = prompt(connection, text: "Second turn", recorder: secondRecorder)
        _ = await secondRecorder.nextEvent()
        _ = await transport.nextSentMessage()
        try await transport.feed(permissionRequest(
            id: reusedID,
            options: [permissionOption(id: "once", name: "Once", kind: "allow_once")]))
        guard case let .permissionRequested(secondPermission) = await secondRecorder.nextEvent() else {
            Issue.record("Expected the second permission event")
            return
        }
        #expect(firstPermission.turnToken != secondPermission.turnToken)
        let messageCount = await transport.allSentMessages().count

        await connection.resolvePermission(
            turnToken: firstPermission.turnToken,
            requestID: reusedID,
            optionID: "once")

        #expect(await transport.allSentMessages().count == messageCount)

        await connection.resolvePermission(
            turnToken: secondPermission.turnToken,
            requestID: reusedID,
            optionID: "once")
        #expect(await transport.nextSentMessage() == permissionSelection(
            id: reusedID,
            optionID: "once"))
        try await transport.feed(promptResponse(id: 4, stopReason: "end_turn"))
        _ = try await secondPrompt.value
        await connection.close()
    }

    @Test func permission_WhenPolicyRejects_ReturnsOfferedRejectOption() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport, policy: .reject)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Delete", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        try await transport.feed(permissionRequest(
            id: .null,
            options: [
                permissionOption(id: "never", name: "Never", kind: "reject_always"),
                permissionOption(id: "not-now", name: "Not now", kind: "reject_once"),
            ]))

        #expect(await transport.nextSentMessage() == permissionSelection(
            id: .null,
            optionID: "not-now"))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await promptTask.value
        await connection.close()
    }

    @Test func permission_WhenRejectOnceIsUnavailable_ReturnsCancelled() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport, policy: .reject)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Delete", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        try await transport.feed(permissionRequest(
            id: .integer(9),
            options: [permissionOption(
                id: "never",
                name: "Never",
                kind: "reject_always")]))

        #expect(await transport.nextSentMessage() == permissionCancellation(id: .integer(9)))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await promptTask.value
        await connection.close()
    }

    @Test func cancel_WhenPromptIsActive_SendsSessionCancelAndCancelsPermissions() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport, policy: .ask)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Edit", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        let requestID = ACPRequestID.string("pending-permission")
        try await transport.feed(permissionRequest(
            id: requestID,
            options: [permissionOption(id: "once", name: "Once", kind: "allow_once")]))
        _ = await recorder.nextEvent()

        await connection.cancel()

        #expect(await transport.nextSentMessage() == permissionCancellation(id: requestID))
        #expect(await transport.nextSentMessage() == .notification(
            method: "session/cancel",
            params: .object(["sessionId": .string("session-1")])))

        try await transport.feed(sessionUpdate(.object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object([
                "type": .string("text"),
                "text": .string("Final update"),
            ]),
        ])))
        #expect(await recorder.nextEvent() == .agentMessageDelta(
            messageID: nil,
            text: "Final update"))
        try await transport.feed(promptResponse(id: 3, stopReason: "cancelled"))
        #expect(try await promptTask.value == AgentRunResult(stopReason: .cancelled))
        await connection.close()
    }

    @Test func cancel_WhenPermissionArrivesAfterCancellation_ReturnsCancelledAndKeepsReading() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport, policy: .allowOnce)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Edit", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()

        await connection.cancel()
        #expect(await transport.nextSentMessage() == .notification(
            method: "session/cancel",
            params: .object(["sessionId": .string("session-1")])))

        try await transport.feed(permissionRequest(
            id: .integer(99),
            options: [permissionOption(id: "once", name: "Once", kind: "allow_once")]))
        #expect(await transport.nextSentMessage() == permissionCancellation(id: .integer(99)))
        try await transport.feed(promptResponse(id: 3, stopReason: "cancelled"))
        _ = try await promptTask.value
        await connection.close()
    }

    @Test func cancel_WhenConnectedCallbackIsSuspended_PublishesPromptBeforeCancel() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let connectedGate = AgentEventGate()
        let promptTask = Task {
            try await connection.prompt("Cancel during publication") { event in
                if case .connected = event {
                    await connectedGate.pause()
                }
            }
        }
        await connectedGate.waitUntilEntered()

        await connection.cancel()
        await connectedGate.open()

        #expect(await transport.nextSentMessage() == .request(
            id: .integer(3),
            method: "session/prompt",
            params: .object([
                "sessionId": .string("session-1"),
                "prompt": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Cancel during publication"),
                    ]),
                ]),
            ])))
        #expect(await transport.nextSentMessage() == .notification(
            method: "session/cancel",
            params: .object(["sessionId": .string("session-1")])))

        try await transport.feed(promptResponse(id: 3, stopReason: "cancelled"))
        #expect(try await promptTask.value == AgentRunResult(stopReason: .cancelled))
        await connection.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancel_WhenPromptWriteIsInFlight_DefersCancelUntilPromptIsPublished() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        await transport.suspendNextSend()
        let promptTask = Task {
            try await connection.prompt("Cancel during write") { _ in }
        }
        await transport.waitUntilSendIsSuspended()

        await connection.cancel()

        #expect(await transport.allSentMessages().count == 2)

        await transport.resumeSuspendedSend()
        #expect(await transport.nextSentMessage() == .request(
            id: .integer(3),
            method: "session/prompt",
            params: .object([
                "sessionId": .string("session-1"),
                "prompt": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Cancel during write"),
                    ]),
                ]),
            ])))
        #expect(await transport.nextSentMessage() == .notification(
            method: "session/cancel",
            params: .object(["sessionId": .string("session-1")])))
        try await transport.feed(promptResponse(id: 3, stopReason: "cancelled"))
        #expect(try await promptTask.value == AgentRunResult(stopReason: .cancelled))
        await connection.close()
    }

    @Test func cancel_WhenCancelledPromptReturnsEndTurn_ClosesAndThrows() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Ignore cancellation", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()

        await connection.cancel()
        _ = await transport.nextSentMessage()
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))

        await #expect(throws: ACPClientError.self) {
            try await promptTask.value
        }
        #expect(await transport.observedTerminationCount() == 1)
    }

    @Test func cancel_WhenPromptResponseWasAlreadyReceived_DoesNotCancelCompletedTurn() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Already complete", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        try await transport.feed(.request(
            id: .string("response-barrier"),
            method: "unsupported/barrier",
            params: nil))
        _ = await transport.nextSentMessage()

        await connection.cancel()

        #expect(try await promptTask.value == AgentRunResult(stopReason: .endTurn))
        #expect(await transport.allSentMessages().contains { message in
            guard case let .notification(method, _) = message else {
                return false
            }
            return method == "session/cancel"
        } == false)
        await connection.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func close_WhenEventCallbackReentersClose_DoesNotAwaitTheReceiveTaskFromItself() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let callbackReturned = AgentEventSignal()
        let promptTask = Task {
            try await connection.prompt("Close from callback") { event in
                guard case .agentMessageDelta = event else {
                    return
                }
                await connection.close()
                await callbackReturned.signal()
            }
        }
        _ = await transport.nextSentMessage()

        try await transport.feed(sessionUpdate(.object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object([
                "type": .string("text"),
                "text": .string("Close now"),
            ]),
        ])))

        await callbackReturned.wait()
        await #expect(throws: ACPClientError.connectionClosed) {
            try await promptTask.value
        }
        #expect(await transport.observedTerminationCount() == 1)
    }

    @Test func receive_WhenUnknownInboundRequestArrives_ReturnsMethodNotFound() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Wait", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        let requestID = ACPRequestID.string("unknown-request")
        try await transport.feed(.request(
            id: requestID,
            method: "provider/do_private_thing",
            params: .object(["secret": .string("discard")])) )

        #expect(await transport.nextSentMessage() == .errorResponse(
            id: requestID,
            error: ACPJSONRPCError(code: -32_601, message: "Method not found")))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await promptTask.value
        await connection.close()
    }

    @Test func receive_WhenCursorQuestionArrives_ReturnsCancelledAndPublishesDiagnostic() async throws {
        try await assertCursorBlockingRequestIsCancelled(method: "cursor/ask_question")
    }

    @Test func receive_WhenCursorCreatePlanArrives_ReturnsCancelledAndPublishesDiagnostic() async throws {
        try await assertCursorBlockingRequestIsCancelled(method: "cursor/create_plan")
    }

    @Test func receive_WhenCursorNotificationArrives_PublishesDiagnosticWithoutResponse() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Wait", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        try await transport.feed(.notification(
            method: "cursor/update_todos",
            params: .object(["private": .string(String(repeating: "x", count: 2_000))])))

        guard case let .diagnostic(summary) = await recorder.nextEvent() else {
            Issue.record("Expected a diagnostic")
            return
        }
        #expect(summary.utf8.count <= ACPClientConnection.maximumDiagnosticBytes)
        #expect(summary.contains("cursor/update_todos"))
        #expect(await transport.allSentMessages().count == 3)
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await promptTask.value
        await connection.close()
    }

    @Test func receive_WhenStaleResponseArrives_IgnoresItAndPublishesDiagnostic() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Wait", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        try await transport.feed(.response(id: .integer(999), result: .object([:])))

        guard case let .diagnostic(summary) = await recorder.nextEvent() else {
            Issue.record("Expected a diagnostic")
            return
        }
        #expect(summary.contains("unknown response"))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await promptTask.value
        await connection.close()
    }

    @Test func close_WhenRequestsArePending_ResumesEveryContinuationWithClosedError() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Never answer", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()

        await connection.close()

        await #expect(throws: ACPClientError.connectionClosed) {
            try await promptTask.value
        }
        #expect(await transport.observedTerminationCount() == 1)
    }

    @Test func receive_WhenEOFHasPendingRequest_ResumesItWithClosedError() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Never answer", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()

        await transport.finishOutput()

        await #expect(throws: ACPClientError.connectionClosed) {
            try await promptTask.value
        }
    }

    @Test func receive_WhenTransportErrorsWithPendingRequest_ResumesItWithClosedError() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Never answer", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()

        await transport.failOutput()

        await #expect(throws: ACPClientError.connectionClosed) {
            try await promptTask.value
        }
    }

    private func establishConnection(
        transport: FakeACPTransport,
        policy: AgentPermissionPolicy = .ask) async throws -> ACPClientConnection
    {
        let connectionTask = Task {
            try await ACPClientConnection.connect(
                transport: transport,
                configuration: try makeConfiguration(policy: policy))
        }
        _ = await transport.nextSentMessage()
        try await transport.feed(initializeResponse())
        _ = await transport.nextSentMessage()
        try await transport.feed(.response(
            id: .integer(2),
            result: .object(["sessionId": .string("session-1")])))
        return try await connectionTask.value
    }

    private func prompt(
        _ connection: ACPClientConnection,
        text: String,
        recorder: AgentEventRecorder) -> Task<AgentRunResult, any Error>
    {
        Task {
            try await connection.prompt(
                text,
                onEvent: { event in await recorder.record(event) })
        }
    }

    private func assertCursorBlockingRequestIsCancelled(method: String) async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Wait", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        let requestID = ACPRequestID.string("cursor-extension")
        try await transport.feed(.request(
            id: requestID,
            method: method,
            params: .object(["private": .string(String(repeating: "x", count: 2_000))])))

        #expect(await transport.nextSentMessage() == .response(
            id: requestID,
            result: .object([
                "outcome": .object(["outcome": .string("cancelled")]),
            ])))
        guard case let .diagnostic(summary) = await recorder.nextEvent() else {
            Issue.record("Expected a diagnostic")
            return
        }
        #expect(summary.utf8.count <= ACPClientConnection.maximumDiagnosticBytes)
        #expect(summary.contains(method))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await promptTask.value
        await connection.close()
    }

    private func makeConfiguration(
        policy: AgentPermissionPolicy = .ask) throws -> AgentHarnessConfiguration
    {
        try AgentHarnessConfiguration(
            preset: .codex,
            displayName: "Configured Agent",
            executablePath: "/usr/bin/agent",
            arguments: ["acp"],
            workingDirectory: "/tmp/project",
            permissionPolicy: policy)
    }

    private func initializeResponse(
        protocolVersion: Int64 = 1,
        authMethods: [ACPJSONValue] = []) -> ACPMessage
    {
        .response(
            id: .integer(1),
            result: .object([
                "protocolVersion": .integer(protocolVersion),
                "agentCapabilities": .object([:]),
                "agentInfo": .object([
                    "name": .string("test-agent"),
                    "title": .string("Test Agent"),
                    "version": .string("2.0.0"),
                ]),
                "authMethods": .array(authMethods),
            ]))
    }

    private func authMethod(id: String, name: String) -> ACPJSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "description": .string("Authenticate outside the client"),
        ])
    }

    private func sessionUpdate(_ update: ACPJSONValue) -> ACPMessage {
        .notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("session-1"),
                "update": update,
            ]))
    }

    private func promptResponse(id: Int64, stopReason: String) -> ACPMessage {
        .response(
            id: .integer(id),
            result: .object(["stopReason": .string(stopReason)]))
    }

    private func permissionRequest(
        id: ACPRequestID,
        options: [ACPJSONValue]) -> ACPMessage
    {
        .request(
            id: id,
            method: "session/request_permission",
            params: .object([
                "sessionId": .string("session-1"),
                "toolCall": .object([
                    "toolCallId": .string("tool-1"),
                    "title": .string("Edit a file"),
                    "kind": .string("edit"),
                    "status": .string("pending"),
                ]),
                "options": .array(options),
            ]))
    }

    private func permissionOption(id: String, name: String, kind: String) -> ACPJSONValue {
        .object([
            "optionId": .string(id),
            "name": .string(name),
            "kind": .string(kind),
        ])
    }

    private func permissionSelection(id: ACPRequestID, optionID: String) -> ACPMessage {
        .response(
            id: id,
            result: .object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string(optionID),
                ]),
            ]))
    }

    private func permissionCancellation(id: ACPRequestID) -> ACPMessage {
        .response(
            id: id,
            result: .object([
                "outcome": .object(["outcome": .string("cancelled")]),
            ]))
    }
}

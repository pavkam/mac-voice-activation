// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore


extension ACPClientConnectionTests {
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
                        "text": .string(ACPClientConnection.markdownPresentationInstruction),
                    ]),
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
                        "text": .string(ACPClientConnection.markdownPresentationInstruction),
                    ]),
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

    @Test(.timeLimit(.minutes(1)))
    func close_WhenCallbackReentersAfterPromptResponse_DoesNotReturnStaleSuccess() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport)
        let connectedGate = AgentEventGate()
        let callbackReturned = AgentEventSignal()
        let promptTask = Task {
            try await connection.prompt("Close after response") { event in
                switch event {
                case .connected:
                    await connectedGate.pause()
                case .agentMessageDelta:
                    await connection.close()
                    await callbackReturned.signal()
                default:
                    break
                }
            }
        }
        _ = await transport.nextSentMessage()
        await connectedGate.waitUntilEntered()
        try await transport.feed(sessionUpdate(.object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object([
                "type": .string("text"),
                "text": .string("Close after the response is accepted"),
            ]),
        ])))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))

        await connectedGate.open()
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

}

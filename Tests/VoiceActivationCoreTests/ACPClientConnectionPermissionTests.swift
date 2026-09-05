// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore


extension ACPClientConnectionTests {
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

    @Test func permission_WhenPolicyAllowsAlways_PrefersOfferedAllowAlwaysOption() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport, policy: .allowAlways)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Edit", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        try await transport.feed(permissionRequest(
            id: .integer(42),
            options: [
                permissionOption(id: "once", name: "Once", kind: "allow_once"),
                permissionOption(id: "always", name: "Always", kind: "allow_always"),
            ]))

        #expect(await transport.nextSentMessage() == permissionSelection(
            id: .integer(42),
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

    @Test func permission_WhenThirtyThirdAskRequestArrives_CancelsOnlyTheExcessAndResolvesEachOnce()
        async throws
    {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport, policy: .ask)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Many permissions", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        let labels = (0...ACPClientConnection.maximumPendingPermissions).map { "Exact label 🧪 \($0)" }

        for index in labels.indices {
            try await transport.feed(permissionRequest(
                id: .string("permission-\(index)"),
                options: [permissionOption(
                    id: "once-\(index)",
                    name: labels[index],
                    kind: "allow_once")]))
        }

        #expect(await transport.nextSentMessage() == permissionCancellation(
            id: .string("permission-\(ACPClientConnection.maximumPendingPermissions)")))
        var admittedLabels: [String] = []
        for _ in 0..<ACPClientConnection.maximumPendingPermissions {
            guard case let .permissionRequested(permission) = await recorder.nextEvent() else {
                Issue.record("Expected an admitted permission")
                return
            }
            admittedLabels.append(permission.options[0].label)
        }
        #expect(admittedLabels == Array(labels.prefix(ACPClientConnection.maximumPendingPermissions)))

        await connection.close()
        await #expect(throws: ACPClientError.connectionClosed) {
            try await promptTask.value
        }
        let responses = await transport.allSentMessages().compactMap { message -> ACPRequestID? in
            guard case let .response(id, result) = message,
                  result == .object([
                      "outcome": .object(["outcome": .string("cancelled")]),
                  ])
            else {
                return nil
            }
            return id
        }
        #expect(responses.count == ACPClientConnection.maximumPendingPermissions + 1)
        #expect(Set(responses).count == responses.count)
    }

    @Test func permission_WhenOpaqueValuesOrOptionCountAreOversized_CancelsWithoutRetention()
        async throws
    {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport, policy: .ask)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Reject oversized", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        let oversizedID = String(
            repeating: "i",
            count: ACPEventDecoder.maximumOpaqueIdentifierBytes + 1)
        let fixtures: [(ACPRequestID, String, [ACPJSONValue])] = [
            (
                .string(oversizedID),
                "tool",
                [permissionOption(id: "once", name: "Once", kind: "allow_once")]),
            (
                .string("oversized-tool"),
                oversizedID,
                [permissionOption(id: "once", name: "Once", kind: "allow_once")]),
            (
                .string("oversized-option"),
                "tool",
                [permissionOption(id: oversizedID, name: "Once", kind: "allow_once")]),
            (
                .string("too-many-options"),
                "tool",
                (0...AgentRunEventDelivery.maximumPermissionOptions).map { index in
                    permissionOption(id: "option-\(index)", name: "Option \(index)", kind: "allow_once")
                }),
            (
                .string("oversized-label"),
                "tool",
                [permissionOption(
                    id: "once",
                    name: String(
                        repeating: "l",
                        count: AgentRunEventDelivery.maximumPendingControlBytes + 1),
                    kind: "allow_once")]),
        ]

        for (id, toolID, options) in fixtures {
            try await transport.feed(permissionRequest(id: id, toolID: toolID, options: options))
            #expect(await transport.nextSentMessage() == permissionCancellation(id: id))
        }
        #expect(await recorder.recordedEvents().isEmpty)

        await connection.close()
        await #expect(throws: ACPClientError.connectionClosed) {
            try await promptTask.value
        }
        let responses = await transport.allSentMessages().filter { message in
            guard case let .response(id, _) = message else {
                return false
            }
            return fixtures.contains { $0.0 == id }
        }
        #expect(responses.count == fixtures.count)
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
        #expect(await transport.nextSentMessage() == permissionCancellation(id: reusedID))
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

    @Test func permission_WhenConnectionsReuseWireID_IgnoresOtherConnectionTurnToken() async throws {
        let firstTransport = FakeACPTransport()
        let firstConnection = try await establishConnection(transport: firstTransport)
        let firstRecorder = AgentEventRecorder()
        let firstPrompt = prompt(
            firstConnection,
            text: "First connection",
            recorder: firstRecorder)
        _ = await firstRecorder.nextEvent()
        _ = await firstTransport.nextSentMessage()
        let reusedID = ACPRequestID.string("reused-across-connections")
        try await firstTransport.feed(permissionRequest(
            id: reusedID,
            options: [permissionOption(id: "once", name: "Once", kind: "allow_once")]))
        guard case let .permissionRequested(firstPermission) = await firstRecorder.nextEvent() else {
            Issue.record("Expected the first connection permission event")
            return
        }

        let secondTransport = FakeACPTransport()
        let secondConnection = try await establishConnection(transport: secondTransport)
        let secondRecorder = AgentEventRecorder()
        let secondPrompt = prompt(
            secondConnection,
            text: "Second connection",
            recorder: secondRecorder)
        _ = await secondRecorder.nextEvent()
        _ = await secondTransport.nextSentMessage()
        try await secondTransport.feed(permissionRequest(
            id: reusedID,
            options: [permissionOption(id: "once", name: "Once", kind: "allow_once")]))
        guard case let .permissionRequested(secondPermission) = await secondRecorder.nextEvent()
        else {
            Issue.record("Expected the second connection permission event")
            return
        }
        #expect(firstPermission.turnToken != secondPermission.turnToken)
        let secondMessageCount = await secondTransport.allSentMessages().count

        await secondConnection.resolvePermission(
            turnToken: firstPermission.turnToken,
            requestID: reusedID,
            optionID: "once")

        #expect(await secondTransport.allSentMessages().count == secondMessageCount)

        await secondConnection.resolvePermission(
            turnToken: secondPermission.turnToken,
            requestID: reusedID,
            optionID: "once")
        #expect(await secondTransport.nextSentMessage() == permissionSelection(
            id: reusedID,
            optionID: "once"))

        await firstConnection.close()
        await #expect(throws: ACPClientError.connectionClosed) {
            try await firstPrompt.value
        }
        try await secondTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await secondPrompt.value
        await secondConnection.close()
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

    @Test func permission_WhenPolicyRejectsAlways_PrefersOfferedRejectAlwaysOption() async throws {
        let transport = FakeACPTransport()
        let connection = try await establishConnection(transport: transport, policy: .rejectAlways)
        let recorder = AgentEventRecorder()
        let promptTask = prompt(connection, text: "Delete", recorder: recorder)
        _ = await recorder.nextEvent()
        _ = await transport.nextSentMessage()
        try await transport.feed(permissionRequest(
            id: .integer(10),
            options: [
                permissionOption(id: "not-now", name: "Not now", kind: "reject_once"),
                permissionOption(id: "never", name: "Never", kind: "reject_always"),
            ]))

        #expect(await transport.nextSentMessage() == permissionSelection(
            id: .integer(10),
            optionID: "never"))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await promptTask.value
        await connection.close()
    }

}

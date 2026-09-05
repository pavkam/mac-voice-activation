// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore


extension ACPClientConnectionTests {
    func establishConnection(
        transport: FakeACPTransport,
        policy: AgentPermissionPolicy = .ask,
        preset: AgentHarnessPreset = .codex,
        systemPrompt: String = "") async throws -> ACPClientConnection
    {
        let connectionTask = Task {
            try await ACPClientConnection.connect(
                transport: transport,
                configuration: try makeConfiguration(
                    policy: policy,
                    preset: preset,
                    systemPrompt: systemPrompt))
        }
        _ = await transport.nextSentMessage()
        try await transport.feed(initializeResponse())
        _ = await transport.nextSentMessage()
        try await transport.feed(.response(
            id: .integer(2),
            result: .object(["sessionId": .string("session-1")])))
        return try await connectionTask.value
    }

    func prompt(
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

    func assertCursorBlockingRequestIsCancelled(method: String) async throws {
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

    func makeConfiguration(
        policy: AgentPermissionPolicy = .ask,
        preset: AgentHarnessPreset = .codex,
        systemPrompt: String = "") throws -> AgentHarnessConfiguration
    {
        try AgentHarnessConfiguration(
            preset: preset,
            displayName: "Configured Agent",
            executablePath: "/usr/bin/agent",
            arguments: ["acp"],
            workingDirectory: "/tmp/project",
            permissionPolicy: policy,
            systemPrompt: systemPrompt)
    }

    func initializeResponse(
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

    func authMethod(id: String, name: String) -> ACPJSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "description": .string("Authenticate outside the client"),
        ])
    }

    func sessionUpdate(
        _ update: ACPJSONValue,
        sessionID: String = "session-1") -> ACPMessage
    {
        .notification(
            method: "session/update",
            params: .object([
                "sessionId": .string(sessionID),
                "update": update,
            ]))
    }

    func promptResponse(id: Int64, stopReason: String) -> ACPMessage {
        .response(
            id: .integer(id),
            result: .object(["stopReason": .string(stopReason)]))
    }

    func permissionRequest(
        id: ACPRequestID,
        toolID: String = "tool-1",
        options: [ACPJSONValue]) -> ACPMessage
    {
        .request(
            id: id,
            method: "session/request_permission",
            params: .object([
                "sessionId": .string("session-1"),
                "toolCall": .object([
                    "toolCallId": .string(toolID),
                    "title": .string("Edit a file"),
                    "kind": .string("edit"),
                    "status": .string("pending"),
                ]),
                "options": .array(options),
            ]))
    }

    func permissionOption(id: String, name: String, kind: String) -> ACPJSONValue {
        .object([
            "optionId": .string(id),
            "name": .string(name),
            "kind": .string(kind),
        ])
    }

    func permissionSelection(id: ACPRequestID, optionID: String) -> ACPMessage {
        .response(
            id: id,
            result: .object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string(optionID),
                ]),
            ]))
    }

    func permissionCancellation(id: ACPRequestID) -> ACPMessage {
        .response(
            id: id,
            result: .object([
                "outcome": .object(["outcome": .string("cancelled")]),
            ]))
    }
}

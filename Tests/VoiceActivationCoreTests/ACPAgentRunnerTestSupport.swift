// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore


extension ACPAgentRunnerTests {
    func run(
        _ runner: ACPAgentRunner,
        profileID: UUID,
        configuration: AgentHarnessConfiguration,
        prompt: String = "First") -> Task<AgentRunResult, any Error>
    {
        Task {
            try await runner.run(
                profileID: profileID,
                configuration: configuration,
                prompt: prompt,
                onEvent: { _ in })
        }
    }

    func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool) async -> Bool
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    func establishConnection(
        _ transport: FakeACPTransport,
        workingDirectory: String,
        sessionID: String = "session-1") async throws
    {
        #expect(await transport.nextSentMessage() == .request(
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
        try await transport.feed(.response(
            id: .integer(1),
            result: .object([
                "protocolVersion": .integer(1),
                "agentCapabilities": .object([:]),
                "agentInfo": .object([
                    "name": .string("test-agent"),
                    "title": .string("Test Agent"),
                    "version": .string("1.0.0"),
                ]),
                "authMethods": .array([]),
            ])))
        #expect(await transport.nextSentMessage() == .request(
            id: .integer(2),
            method: "session/new",
            params: .object([
                "cwd": .string(workingDirectory),
                "mcpServers": .array([]),
            ])))
        try await transport.feed(.response(
            id: .integer(2),
            result: .object(["sessionId": .string(sessionID)])))
    }

    func makeConfiguration(
        workingDirectory: String = "/tmp/project") throws -> AgentHarnessConfiguration
    {
        try AgentHarnessConfiguration(
            preset: .codex,
            displayName: "Configured Agent",
            executablePath: "/usr/bin/agent",
            arguments: ["acp"],
            workingDirectory: workingDirectory,
            permissionPolicy: .ask)
    }

    func promptRequest(
        id: Int64,
        text: String,
        sessionID: String = "session-1") -> ACPMessage
    {
        .request(
            id: .integer(id),
            method: "session/prompt",
            params: .object([
                "sessionId": .string(sessionID),
                "prompt": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(ACPClientConnection.markdownPresentationInstruction),
                    ]),
                    .object([
                        "type": .string("text"),
                        "text": .string(text),
                    ]),
                ]),
            ]))
    }

    func promptResponse(id: Int64, stopReason: String) -> ACPMessage {
        .response(
            id: .integer(id),
            result: .object(["stopReason": .string(stopReason)]))
    }

    func permissionRequest(id: ACPRequestID) -> ACPMessage {
        .request(
            id: id,
            method: "session/request_permission",
            params: .object([
                "sessionId": .string("session-1"),
                "toolCall": .object([
                    "toolCallId": .string("tool-1"),
                    "title": .string("Edit"),
                    "kind": .string("edit"),
                    "status": .string("pending"),
                ]),
                "options": .array([
                    .object([
                        "optionId": .string("once"),
                        "name": .string("Allow once"),
                        "kind": .string("allow_once"),
                    ]),
                ]),
            ]))
    }

    func agentMessageUpdate(text: String) -> ACPMessage {
        .notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("session-1"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(text),
                    ]),
                ]),
            ]))
    }

    func modeUpdate(id: String) -> ACPMessage {
        .notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("session-1"),
                "update": .object([
                    "sessionUpdate": .string("current_mode_update"),
                    "currentModeId": .string(id),
                ]),
            ]))
    }

    func isSessionCreation(_ message: ACPMessage) -> Bool {
        guard case let .request(_, method, _) = message else {
            return false
        }
        return method == "session/new"
    }
}

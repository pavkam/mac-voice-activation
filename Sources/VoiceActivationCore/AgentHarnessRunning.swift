// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

public enum AgentStopReason: String, Codable, Equatable, Sendable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled
}

public struct AgentRunResult: Equatable, Sendable {
    public let stopReason: AgentStopReason

    public init(stopReason: AgentStopReason) {
        self.stopReason = stopReason
    }
}

public protocol AgentHarnessRunning: Sendable {
    func run(
        profileID: UUID,
        configuration: AgentHarnessConfiguration,
        prompt: String,
        onEvent: @escaping @Sendable (AgentRunEvent) async -> Void
    ) async throws -> AgentRunResult

    func resolvePermission(
        turnToken: AgentTurnToken,
        requestID: ACPRequestID,
        optionID: String?) async
    func cancel() async
    func reset(profileIDs: Set<UUID>) async
    func shutdown() async
}

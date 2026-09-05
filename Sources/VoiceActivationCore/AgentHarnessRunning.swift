// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// The ACP stop reason that completed an agent turn.
public enum AgentStopReason: String, Codable, Equatable, Sendable {
    /// The agent deliberately finished the turn.
    case endTurn = "end_turn"
    /// The model reached its token limit.
    case maxTokens = "max_tokens"
    /// The harness reached its per-turn request limit.
    case maxTurnRequests = "max_turn_requests"
    /// The agent refused the request.
    case refusal
    /// The local user cancelled the turn.
    case cancelled
}

/// The terminal result of one agent turn.
public struct AgentRunResult: Equatable, Sendable {
    /// The reason the harness reports for ending the turn.
    public let stopReason: AgentStopReason

    /// Creates an agent result from its terminal stop reason.
    ///
    /// - Parameter stopReason: The reason the turn ended.
    public init(stopReason: AgentStopReason) {
        self.stopReason = stopReason
    }
}

/// Runs ACP turns and manages their cached conversation sessions.
public protocol AgentHarnessRunning: Sendable {
    /// Runs one prompt in the profile's reusable conversation session.
    ///
    /// - Parameters:
    ///   - profileID: The wake profile that owns the cached session.
    ///   - configuration: The harness launch and permission configuration.
    ///   - prompt: The user utterance and configured instructions.
    ///   - onEvent: An asynchronous sink for ordered streaming events.
    /// - Returns: The turn's terminal stop reason.
    /// - Throws: A transport, protocol, launch, or cancellation error.
    func run(
        profileID: UUID,
        configuration: AgentHarnessConfiguration,
        prompt: String,
        onEvent: @escaping @Sendable (AgentRunEvent) async -> Void
    ) async throws -> AgentRunResult

    /// Answers one pending permission request for the active turn.
    ///
    /// - Parameters:
    ///   - turnToken: The turn identity that owns the request.
    ///   - requestID: The ACP request identifier.
    ///   - optionID: The chosen harness option, or `nil` to cancel the request.
    func resolvePermission(
        turnToken: AgentTurnToken,
        requestID: ACPRequestID,
        optionID: String?) async
    /// Cancels the active turn without discarding unrelated cached sessions.
    func cancel() async
    /// Discards cached sessions belonging to the supplied profiles.
    ///
    /// - Parameter profileIDs: Profile identities whose sessions are no longer valid.
    func reset(profileIDs: Set<UUID>) async
    /// Cancels active work and closes every cached harness process.
    func shutdown() async
}

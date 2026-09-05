// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// Local lifecycle failures produced while managing reusable ACP sessions.
public enum ACPAgentRunnerError: Error, Equatable, LocalizedError, Sendable {
    /// The user cancelled the active turn.
    case cancelled
    /// The runner has permanently shut down.
    case shutDown
    /// A second prompt arrived before the active prompt completed.
    case turnAlreadyActive
    /// Required control events exceeded the bounded delivery queue.
    case eventDeliveryOverflow
    /// ACP initialization did not complete before the startup deadline.
    case startupTimedOut

    /// A user-presentable explanation of the runner failure.
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            "The agent run was cancelled."
        case .shutDown:
            "The agent runner has shut down."
        case .turnAlreadyActive:
            "Another agent prompt is already active."
        case .eventDeliveryOverflow:
            "The agent produced more control events than can be delivered safely."
        case .startupTimedOut:
            "The agent did not finish starting within 12 seconds."
        }
    }
}

/// A replaceable asynchronous delay source used by runner deadlines and tests.
public protocol ACPAgentRunnerClock: Sendable {
    /// Suspends for the supplied logical duration.
    ///
    /// - Parameter duration: The amount of time to wait.
    func sleep(for duration: Duration) async
}

/// The production runner clock backed by Swift's monotonic continuous clock.
public struct ContinuousACPAgentRunnerClock: ACPAgentRunnerClock, Sendable {
    /// Creates a monotonic runner clock.
    public init() {}

    /// Suspends for the requested duration unless the surrounding task ends first.
    ///
    /// - Parameter duration: The amount of time to wait.
    public func sleep(for duration: Duration) async {
        try? await ContinuousClock().sleep(for: duration)
    }
}

struct ACPAgentRunnerTestingHooks: Sendable {
    let beforeCancelledExitWaitReturns: @Sendable () async -> Void
    let beforeSuccessIsPublished: @Sendable () async -> Void

    init(
        beforeCancelledExitWaitReturns: @escaping @Sendable () async -> Void = {},
        beforeSuccessIsPublished: @escaping @Sendable () async -> Void = {}
    ) {
        self.beforeCancelledExitWaitReturns = beforeCancelledExitWaitReturns
        self.beforeSuccessIsPublished = beforeSuccessIsPublished
    }
}

/// Owns bounded reusable ACP processes and serializes their active turns.
public actor ACPAgentRunner: AgentHarnessRunning {
    /// The maximum retained standard-error tail for failed harness diagnostics.
    public static let maximumStandardErrorBytes = 16 * 1_024
    /// The maximum number of idle profile sessions retained simultaneously.
    public static let maximumCachedSessions = 4

    static let maximumTrackedSessionEvictions = 64
    static let sessionRecoveryNotice =
        "The previous agent session was unavailable, so a fresh session was started."
    static let sessionEvictionNotice =
        "This profile's previous agent session was released to keep resource use bounded, "
        + "so a fresh session was started."
    static let startupRecoveryNotice =
        "Agent startup stalled, so a fresh connection was started."

    static let connectionStartupTimeout = Duration.seconds(12)
    static let cancellationGracePeriod = Duration.seconds(2)
    static let exitDrainGracePeriod = Duration.milliseconds(500)
    static let promptSettlePeriod = Duration.milliseconds(25)

    let transportFactory: any ACPTransportCreating
    let clock: any ACPAgentRunnerClock
    let startupClock: any ACPAgentRunnerClock
    let drainClock: any ACPAgentRunnerClock
    let settleClock: any ACPAgentRunnerClock
    let testingHooks: ACPAgentRunnerTestingHooks
    let diagnostics: any VoiceActivationDiagnosticRecording
    var records: [UUID: ACPAgentConnectionRecord] = [:]
    var activeTurn: ACPAgentActiveTurn?
    var isShutDown = false
    var latestAccessOrdinal: UInt64 = 0
    var evictedProfileIDs: [UUID] = []

    /// Creates an ACP runner with replaceable transport, timing, and diagnostics boundaries.
    ///
    /// - Parameters:
    ///   - transportFactory: Creates one process transport per fresh session.
    ///   - clock: Controls cancellation deadlines.
    ///   - drainClock: Controls post-exit stream draining.
    ///   - settleClock: Controls the short successful-prompt process-settlement window.
    ///   - diagnostics: Records privacy-safe lifecycle metadata.
    public init(
        transportFactory: any ACPTransportCreating = ACPProcessTransportFactory(),
        clock: any ACPAgentRunnerClock = ContinuousACPAgentRunnerClock(),
        drainClock: any ACPAgentRunnerClock = ContinuousACPAgentRunnerClock(),
        settleClock: any ACPAgentRunnerClock = ContinuousACPAgentRunnerClock(),
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.transportFactory = transportFactory
        self.clock = clock
        startupClock = ContinuousACPAgentRunnerClock()
        self.drainClock = drainClock
        self.settleClock = settleClock
        testingHooks = ACPAgentRunnerTestingHooks()
        self.diagnostics = diagnostics
    }

    init(
        transportFactory: any ACPTransportCreating = ACPProcessTransportFactory(),
        clock: any ACPAgentRunnerClock = ContinuousACPAgentRunnerClock(),
        startupClock: any ACPAgentRunnerClock = ContinuousACPAgentRunnerClock(),
        drainClock: any ACPAgentRunnerClock = ContinuousACPAgentRunnerClock(),
        settleClock: any ACPAgentRunnerClock = ContinuousACPAgentRunnerClock(),
        testingHooks: ACPAgentRunnerTestingHooks,
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.transportFactory = transportFactory
        self.clock = clock
        self.startupClock = startupClock
        self.drainClock = drainClock
        self.settleClock = settleClock
        self.testingHooks = testingHooks
        self.diagnostics = diagnostics
    }

    /// Runs a prompt using the profile's cached session, recovering stale sessions once.
    ///
    /// - Parameters:
    ///   - profileID: The owner of the reusable ACP session.
    ///   - configuration: The validated process and permission configuration.
    ///   - prompt: The complete prompt sent to the harness.
    ///   - onEvent: Receives ordered streaming output and control events.
    /// - Returns: The terminal result reported by the harness.
    /// - Throws: ``ACPAgentRunnerError`` or an underlying transport/protocol error.
    public func run(
        profileID: UUID,
        configuration: AgentHarnessConfiguration,
        prompt: String,
        onEvent: @escaping @Sendable (AgentRunEvent) async -> Void
    ) async throws
        -> AgentRunResult
    {
        guard !isShutDown else {
            diagnostics.record(
                category: .agent,
                event: "acp_runner.run_rejected",
                fields: ["reason": "shut_down"])
            throw ACPAgentRunnerError.shutDown
        }
        guard activeTurn == nil else {
            diagnostics.record(
                category: .agent,
                event: "acp_runner.run_rejected",
                fields: ["reason": "turn_already_active"])
            throw ACPAgentRunnerError.turnAlreadyActive
        }

        let token = UUID()
        let startedAtUptime = DispatchTime.now().uptimeNanoseconds
        diagnostics.record(
            category: .agent,
            event: "acp_runner.run_started",
            fields: [
                "turn_id": token.uuidString,
                "profile_id": profileID.uuidString,
                "input_character_count": String(prompt.count),
                "cached_session_count": String(records.count),
                "task_priority": String(Task.currentPriority.rawValue),
            ])
        let completion = ACPAgentRunCompletionLatch()
        let delivery = AgentRunEventDelivery { [diagnostics] event in
            let deliveryStartedAtUptime = DispatchTime.now().uptimeNanoseconds
            diagnostics.record(
                category: .agent,
                event: "acp_runner.delivery_handler_started",
                level: .debug,
                fields: [
                    "turn_id": token.uuidString,
                    "event_kind": event.runnerDiagnosticName,
                    "task_priority": String(Task.currentPriority.rawValue),
                ])
            await onEvent(event)
            diagnostics.record(
                category: .agent,
                event: "acp_runner.delivery_handler_finished",
                level: .debug,
                fields: [
                    "turn_id": token.uuidString,
                    "event_kind": event.runnerDiagnosticName,
                    "duration_ms": String(
                        Self.elapsedMilliseconds(since: deliveryStartedAtUptime)),
                    "task_priority": String(Task.currentPriority.rawValue),
                ])
        }
        activeTurn = ACPAgentActiveTurn(
            token: token,
            profileID: profileID,
            recordID: nil,
            connection: nil,
            completion: completion,
            delivery: delivery,
            isCancelling: false,
            deliveryOverflowed: false)

        var runRecord: ACPAgentConnectionRecord?
        var didAttemptSessionRecovery = false
        var didAttemptStartupRecovery = false
        var shouldPublishSessionRecoveryNotice = false
        var shouldPublishStartupRecoveryNotice = false
        do {
            while true {
                let record: ACPAgentConnectionRecord
                do {
                    record = try await connectionRecord(
                        profileID: profileID,
                        configuration: configuration,
                        turnToken: token)
                } catch let error as ACPAgentRunnerError {
                    guard error == .startupTimedOut,
                        !didAttemptStartupRecovery,
                        ownsActiveTurn(token),
                        !isActiveTurnCancelling(token)
                    else {
                        throw error
                    }
                    didAttemptStartupRecovery = true
                    shouldPublishStartupRecoveryNotice = true
                    diagnostics.record(
                        category: .agent,
                        event: "acp_runner.startup_recovery_started",
                        level: .warning,
                        fields: [
                            "turn_id": token.uuidString,
                            "profile_id": profileID.uuidString,
                        ])
                    continue
                }
                runRecord = record
                guard ownsActiveTurn(token),
                    !isActiveTurnCancelling(token),
                    activeTurn?.deliveryOverflowed == false
                else {
                    if activeTurn?.token == token, activeTurn?.deliveryOverflowed == true {
                        throw ACPAgentRunnerError.eventDeliveryOverflow
                    }
                    throw ACPAgentRunnerError.cancelled
                }
                guard let connection = record.connection else {
                    throw ACPClientError.connectionClosed
                }
                updateActiveTurn(token: token, record: record, connection: connection)
                let recordID = record.id
                if shouldPublishStartupRecoveryNotice {
                    try publishSessionNotice(
                        Self.startupRecoveryNotice,
                        turnToken: token)
                    shouldPublishStartupRecoveryNotice = false
                } else if shouldPublishSessionRecoveryNotice {
                    try publishSessionNotice(
                        Self.sessionRecoveryNotice,
                        turnToken: token)
                    shouldPublishSessionRecoveryNotice = false
                } else if evictedProfileIDs.contains(profileID) {
                    try publishSessionNotice(
                        Self.sessionEvictionNotice,
                        turnToken: token)
                    evictedProfileIDs.removeAll { $0 == profileID }
                }

                let result: AgentRunResult
                do {
                    result = try await connection.prompt(prompt) { [weak self] event in
                        await self?.forward(
                            event: event,
                            turnToken: token,
                            profileID: profileID,
                            recordID: recordID)
                    }
                } catch let error as ACPClientError {
                    guard !didAttemptSessionRecovery,
                        error.isSessionUnavailable,
                        ownsActiveTurn(token),
                        !isActiveTurnCancelling(token)
                    else {
                        throw error
                    }

                    didAttemptSessionRecovery = true
                    diagnostics.record(
                        category: .agent,
                        event: "acp_runner.session_recovery_started",
                        level: .warning,
                        fields: [
                            "turn_id": token.uuidString,
                            "profile_id": profileID.uuidString,
                            "record_id": recordID.uuidString,
                        ])
                    await discardRecord(
                        profileID: profileID,
                        recordID: recordID,
                        fallbackRecord: record)
                    runRecord = nil
                    clearActiveTurnConnection(token: token)
                    try ensureActiveTurn(token: token)
                    shouldPublishSessionRecoveryNotice = true
                    continue
                }
                if isActiveTurnCancelling(token), result.stopReason != .cancelled {
                    throw ACPClientError.malformedResponse(
                        "A cancelled prompt returned a non-cancelled stopReason.")
                }

                if await processExitWasObservedDuringPromptSettlement(record: record) {
                    _ = await record.exitTask?.result
                }

                await delivery.finish(.drain)
                guard activeTurn?.token == token else {
                    throw ACPAgentRunnerError.cancelled
                }
                guard activeTurn?.deliveryOverflowed == false else {
                    throw ACPAgentRunnerError.eventDeliveryOverflow
                }
                await testingHooks.beforeSuccessIsPublished()
                guard activeTurn?.token == token else {
                    throw ACPAgentRunnerError.cancelled
                }
                guard activeTurn?.deliveryOverflowed == false else {
                    throw ACPAgentRunnerError.eventDeliveryOverflow
                }
                if isActiveTurnCancelling(token), result.stopReason != .cancelled {
                    throw ACPAgentRunnerError.cancelled
                }
                clearActiveTurn(token: token)
                await completion.resolve(.success(result))
                diagnostics.record(
                    category: .agent,
                    event: "acp_runner.run_finished",
                    fields: [
                        "turn_id": token.uuidString,
                        "profile_id": profileID.uuidString,
                        "stop_reason": result.stopReason.rawValue,
                        "duration_ms": String(
                            Self.elapsedMilliseconds(
                                since: startedAtUptime)),
                    ])
                return result
            }
        } catch {
            let reportedError: any Error =
                activeTurn?.token == token
                    && activeTurn?.deliveryOverflowed == true
                ? ACPAgentRunnerError.eventDeliveryOverflow
                : error
            if let runRecord, runRecord.exitStatus != nil {
                _ = await runRecord.exitTask?.result
            }
            await delivery.finish(.drain)
            await completion.resolve(.failure)
            if let runRecord {
                await discardRecord(
                    profileID: profileID,
                    recordID: runRecord.id,
                    fallbackRecord: runRecord)
            }
            clearActiveTurn(token: token)
            diagnostics.record(
                category: .agent,
                event: "acp_runner.run_failed",
                level: reportedError is CancellationError ? .info : .error,
                fields: [
                    "turn_id": token.uuidString,
                    "profile_id": profileID.uuidString,
                    "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
                    "error_type": String(describing: type(of: reportedError)),
                ])
            throw reportedError
        }
    }

    /// Answers a permission request only when it belongs to the active turn.
    ///
    /// - Parameters:
    ///   - turnToken: The local identity of the requesting turn.
    ///   - requestID: The JSON-RPC request identifier.
    ///   - optionID: The selected option, or `nil` to cancel the request.
    public func resolvePermission(
        turnToken: AgentTurnToken,
        requestID: ACPRequestID,
        optionID: String?
    ) async {
        guard let connection = activeTurn?.connection else {
            diagnostics.record(
                category: .agent,
                event: "acp_runner.permission_ignored",
                fields: ["reason": "no_connection"])
            return
        }
        diagnostics.record(
            category: .agent,
            event: "acp_runner.permission_resolving",
            fields: ["has_option": String(optionID != nil)])
        await connection.resolvePermission(
            turnToken: turnToken,
            requestID: requestID,
            optionID: optionID)
    }

    /// Requests cooperative cancellation, then evicts an unresponsive process after a deadline.
    public func cancel() async {
        guard var turn = activeTurn, !turn.isCancelling else {
            diagnostics.record(
                category: .agent,
                event: "acp_runner.cancel_ignored",
                fields: ["reason": "no_turn_or_already_cancelling"])
            return
        }
        diagnostics.record(
            category: .agent,
            event: "acp_runner.cancel_started",
            fields: [
                "turn_id": turn.token.uuidString,
                "profile_id": turn.profileID.uuidString,
                "has_connection": String(turn.connection != nil),
            ])
        turn.isCancelling = true
        activeTurn = turn

        let token = turn.token
        let profileID = turn.profileID
        let capturedRecordID = turn.recordID
        let completion = turn.completion
        if let connection = turn.connection {
            Task {
                await connection.cancel()
            }
        }

        var outcome = await raceCancellation(completion: completion)
        if case .deadline = outcome, let completed = await completion.completedValue() {
            outcome = .completion(completed)
        }

        if case .completion(.success(let result)) = outcome,
            result.stopReason == .cancelled
        {
            diagnostics.record(
                category: .agent,
                event: "acp_runner.cancel_finished",
                fields: [
                    "turn_id": token.uuidString,
                    "outcome": "cooperative",
                ])
            return
        }

        diagnostics.record(
            category: .agent,
            event: "acp_runner.cancel_forcing_eviction",
            level: .warning,
            fields: ["turn_id": token.uuidString])
        await forceEvictActiveRecord(
            turnToken: token,
            profileID: profileID,
            capturedRecordID: capturedRecordID)
    }

    /// Discards cached sessions whose profile configuration changed or was removed.
    ///
    /// - Parameter profileIDs: The profile identities to invalidate.
    public func reset(profileIDs: Set<UUID>) async {
        diagnostics.record(
            category: .agent,
            event: "acp_runner.reset_started",
            fields: ["profile_count": String(profileIDs.count)])
        var removed: [ACPAgentConnectionRecord] = []
        var discardedDelivery: AgentRunEventDelivery?
        if let turn = activeTurn, profileIDs.contains(turn.profileID) {
            discardedDelivery = turn.delivery
            activeTurn = nil
        }
        for profileID in profileIDs {
            guard let record = records.removeValue(forKey: profileID) else {
                continue
            }
            removed.append(record)
        }
        evictedProfileIDs.removeAll { profileIDs.contains($0) }

        await discardedDelivery?.finish(.discard)

        for record in removed {
            await dispose(record)
        }
        diagnostics.record(
            category: .agent,
            event: "acp_runner.reset_finished",
            fields: ["disposed_session_count": String(removed.count)])
    }

    /// Permanently stops the runner and disposes every active or cached process.
    public func shutdown() async {
        guard !isShutDown else {
            diagnostics.record(category: .agent, event: "acp_runner.shutdown_ignored")
            return
        }
        diagnostics.record(
            category: .agent,
            event: "acp_runner.shutdown_started",
            fields: ["cached_session_count": String(records.count)])
        isShutDown = true

        if let turn = activeTurn {
            activeTurn = nil
            await turn.delivery.finish(.discard)
            if let connection = turn.connection {
                Task {
                    await connection.cancel()
                }
            }
        }

        let cachedRecords = Array(records.values)
        records.removeAll()
        evictedProfileIDs.removeAll()
        for record in cachedRecords {
            await dispose(record)
        }
        diagnostics.record(
            category: .agent,
            event: "acp_runner.shutdown_finished",
            fields: ["disposed_session_count": String(cachedRecords.count)])
    }

}

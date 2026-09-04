// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

public enum ACPAgentRunnerError: Error, Equatable, LocalizedError, Sendable {
    case cancelled
    case shutDown
    case turnAlreadyActive
    case eventDeliveryOverflow
    case startupTimedOut

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

public protocol ACPAgentRunnerClock: Sendable {
    func sleep(for duration: Duration) async
}

public struct ContinuousACPAgentRunnerClock: ACPAgentRunnerClock, Sendable {
    public init() {}

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

public actor ACPAgentRunner: AgentHarnessRunning {
    public static let maximumStandardErrorBytes = 16 * 1_024
    public static let maximumCachedSessions = 4

    private static let maximumTrackedSessionEvictions = 64
    static let sessionRecoveryNotice =
        "The previous agent session was unavailable, so a fresh session was started."
    static let sessionEvictionNotice =
        "This profile's previous agent session was released to keep resource use bounded, "
        + "so a fresh session was started."
    static let startupRecoveryNotice =
        "Agent startup stalled, so a fresh connection was started."

    private static let connectionStartupTimeout = Duration.seconds(12)
    private static let cancellationGracePeriod = Duration.seconds(2)
    private static let exitDrainGracePeriod = Duration.milliseconds(500)
    private static let promptSettlePeriod = Duration.milliseconds(25)

    private let transportFactory: any ACPTransportCreating
    private let clock: any ACPAgentRunnerClock
    private let startupClock: any ACPAgentRunnerClock
    private let drainClock: any ACPAgentRunnerClock
    private let settleClock: any ACPAgentRunnerClock
    private let testingHooks: ACPAgentRunnerTestingHooks
    private let diagnostics: any VoiceActivationDiagnosticRecording
    private var records: [UUID: ACPAgentConnectionRecord] = [:]
    private var activeTurn: ACPAgentActiveTurn?
    private var isShutDown = false
    private var latestAccessOrdinal: UInt64 = 0
    private var evictedProfileIDs: [UUID] = []

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
            ])
        let completion = ACPAgentRunCompletionLatch()
        let delivery = AgentRunEventDelivery(handler: onEvent)
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

    private func connectionRecord(
        profileID: UUID,
        configuration: AgentHarnessConfiguration,
        turnToken: UUID
    ) async throws -> ACPAgentConnectionRecord {
        if let cached = records[profileID],
            cached.configuration == configuration,
            cached.connection != nil,
            cached.exitStatus == nil
        {
            diagnostics.record(
                category: .agent,
                event: "acp_runner.session_cache_hit",
                fields: [
                    "turn_id": turnToken.uuidString,
                    "profile_id": profileID.uuidString,
                    "record_id": cached.id.uuidString,
                ])
            markAccessed(cached)
            updateActiveTurnRecord(token: turnToken, record: cached)
            return cached
        }

        if let replaced = records.removeValue(forKey: profileID) {
            diagnostics.record(
                category: .agent,
                event: "acp_runner.session_replacing",
                fields: [
                    "profile_id": profileID.uuidString,
                    "record_id": replaced.id.uuidString,
                ])
            await dispose(replaced)
            try ensureActiveTurn(token: turnToken)
        }

        diagnostics.record(
            category: .agent,
            event: "acp_runner.transport_creating",
            fields: [
                "turn_id": turnToken.uuidString,
                "profile_id": profileID.uuidString,
                "provider": configuration.preset.rawValue,
                "executable_path": configuration.executablePath,
            ])
        let transport = try await transportFactory.makeTransport(configuration: configuration)
        guard ownsActiveTurn(turnToken) else {
            await transport.terminate()
            throw ACPAgentRunnerError.cancelled
        }

        let record = ACPAgentConnectionRecord(
            id: UUID(),
            profileID: profileID,
            configuration: configuration,
            transport: transport,
            accessOrdinal: nextAccessOrdinal(),
            beforeCancelledExitWaitReturns: testingHooks.beforeCancelledExitWaitReturns)
        records[profileID] = record
        diagnostics.record(
            category: .agent,
            event: "acp_runner.transport_created",
            fields: [
                "turn_id": turnToken.uuidString,
                "profile_id": profileID.uuidString,
                "record_id": record.id.uuidString,
            ])
        updateActiveTurnRecord(token: turnToken, record: record)
        await startObservers(for: record)

        do {
            let connection = try await connect(
                record: record,
                transport: transport,
                configuration: configuration)
            guard records[profileID]?.id == record.id,
                ownsActiveTurn(turnToken),
                !isActiveTurnCancelling(turnToken)
            else {
                await transport.terminate()
                await connection.close()
                throw ACPAgentRunnerError.cancelled
            }
            record.connection = connection
            diagnostics.record(
                category: .agent,
                event: "acp_runner.connection_ready",
                fields: [
                    "turn_id": turnToken.uuidString,
                    "profile_id": profileID.uuidString,
                    "record_id": record.id.uuidString,
                    "cached_session_count": String(records.count),
                ])
            updateActiveTurn(token: turnToken, record: record, connection: connection)
            try await evictLeastRecentlyUsedSessionIfNeeded(
                preservingRecordID: record.id,
                turnToken: turnToken)
            return record
        } catch {
            diagnostics.record(
                category: .agent,
                event: "acp_runner.connection_failed",
                level: error is CancellationError ? .info : .error,
                fields: [
                    "turn_id": turnToken.uuidString,
                    "profile_id": profileID.uuidString,
                    "record_id": record.id.uuidString,
                    "error_type": String(describing: type(of: error)),
                ])
            if records[profileID]?.id == record.id {
                records.removeValue(forKey: profileID)
            }
            await dispose(record)
            throw error
        }
    }

    private func connect(
        record: ACPAgentConnectionRecord,
        transport: any ACPTransport,
        configuration: AgentHarnessConfiguration
    ) async throws -> ACPClientConnection {
        let startedAtUptime = DispatchTime.now().uptimeNanoseconds
        let connectionDiagnostics = diagnostics
        diagnostics.record(
            category: .acp,
            event: "acp_runner.handshake_started",
            fields: ["record_id": record.id.uuidString])
        let outcome = await withTaskGroup(of: ACPAgentConnectionStartupOutcome.self) { group in
            group.addTask { [startupClock] in
                await startupClock.sleep(for: Self.connectionStartupTimeout)
                return Task.isCancelled ? .cancelled : .timedOut
            }
            group.addTask {
                do {
                    return .connected(
                        try await ACPClientConnection.connect(
                            transport: transport,
                            configuration: configuration,
                            diagnostics: connectionDiagnostics))
                } catch {
                    return .failed(error)
                }
            }

            let first = await group.next() ?? .timedOut
            switch first {
            case .cancelled, .timedOut:
                record.suppressesExitDiagnostic = true
                await transport.terminate()
                await transport.closeReadStreams()
            case .connected, .failed:
                break
            }
            group.cancelAll()
            return first
        }

        switch outcome {
        case .connected(let connection):
            diagnostics.record(
                category: .acp,
                event: "acp_runner.handshake_finished",
                fields: [
                    "record_id": record.id.uuidString,
                    "outcome": "connected",
                    "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
                ])
            return connection
        case .failed(let error):
            diagnostics.record(
                category: .acp,
                event: "acp_runner.handshake_finished",
                level: .error,
                fields: [
                    "record_id": record.id.uuidString,
                    "outcome": "failed",
                    "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
                    "error_type": String(describing: type(of: error)),
                ])
            throw error
        case .cancelled:
            diagnostics.record(
                category: .acp,
                event: "acp_runner.handshake_finished",
                fields: [
                    "record_id": record.id.uuidString,
                    "outcome": "cancelled",
                    "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
                ])
            throw CancellationError()
        case .timedOut:
            diagnostics.record(
                category: .acp,
                event: "acp_runner.handshake_finished",
                level: .error,
                fields: [
                    "record_id": record.id.uuidString,
                    "outcome": "timed_out",
                    "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
                ])
            throw ACPAgentRunnerError.startupTimedOut
        }
    }

    private func evictLeastRecentlyUsedSessionIfNeeded(
        preservingRecordID: UUID,
        turnToken: UUID
    ) async throws {
        guard records.count > Self.maximumCachedSessions,
            let candidate = records.values
                .filter({ $0.id != preservingRecordID })
                .min(by: { left, right in
                    if left.accessOrdinal == right.accessOrdinal {
                        return left.id.uuidString < right.id.uuidString
                    }
                    return left.accessOrdinal < right.accessOrdinal
                })
        else {
            return
        }

        records.removeValue(forKey: candidate.profileID)
        diagnostics.record(
            category: .agent,
            event: "acp_runner.session_evicted",
            fields: [
                "profile_id": candidate.profileID.uuidString,
                "record_id": candidate.id.uuidString,
                "cached_session_count": String(records.count),
            ])
        recordSessionEviction(profileID: candidate.profileID)
        await dispose(candidate)
        try ensureActiveTurn(token: turnToken)
    }

    private func recordSessionEviction(profileID: UUID) {
        evictedProfileIDs.removeAll { $0 == profileID }
        evictedProfileIDs.append(profileID)
        if evictedProfileIDs.count > Self.maximumTrackedSessionEvictions {
            evictedProfileIDs.removeFirst(
                evictedProfileIDs.count - Self.maximumTrackedSessionEvictions)
        }
    }

    private func markAccessed(_ record: ACPAgentConnectionRecord) {
        record.accessOrdinal = nextAccessOrdinal()
    }

    private func nextAccessOrdinal() -> UInt64 {
        if latestAccessOrdinal == .max {
            let ordered = records.values.sorted { left, right in
                if left.accessOrdinal == right.accessOrdinal {
                    return left.id.uuidString < right.id.uuidString
                }
                return left.accessOrdinal < right.accessOrdinal
            }
            for (index, record) in ordered.enumerated() {
                record.accessOrdinal = UInt64(index + 1)
            }
            latestAccessOrdinal = UInt64(ordered.count)
        }

        latestAccessOrdinal += 1
        return latestAccessOrdinal
    }

    private func startObservers(for record: ACPAgentConnectionRecord) async {
        diagnostics.record(
            category: .acp,
            event: "acp_runner.process_observers_started",
            fields: [
                "profile_id": record.profileID.uuidString,
                "record_id": record.id.uuidString,
            ])
        let diagnostics = await record.transport.diagnostics()
        let transport = record.transport
        let profileID = record.profileID
        let recordID = record.id
        record.diagnosticsTask = Task { [weak self] in
            for await data in diagnostics {
                if Task.isCancelled {
                    return
                }
                await self?.receivedDiagnostic(
                    data,
                    profileID: profileID,
                    recordID: recordID)
            }
            await self?.finishedDiagnostics(
                profileID: profileID,
                recordID: recordID)
        }
        let diagnosticsTask = record.diagnosticsTask
        record.exitTask = Task { [weak self] in
            let status = await transport.waitForExit()
            guard
                await self?.markProcessExited(
                    status: status,
                    profileID: profileID,
                    recordID: recordID) == true
            else {
                return
            }

            let drainResult = await self?.raceDrain(transport: transport) ?? .deadline
            if case .deadline = drainResult {
                await transport.closeReadStreams()
            }
            await transport.waitForDrain()
            _ = await diagnosticsTask?.result
            await self?.processDrained(
                profileID: profileID,
                recordID: recordID)
        }
    }

    private func receivedDiagnostic(_ data: Data, profileID: UUID, recordID: UUID) {
        guard let record = records[profileID], record.id == recordID else {
            return
        }
        diagnostics.record(
            category: .acp,
            event: "acp_runner.standard_error_received",
            level: .debug,
            fields: [
                "profile_id": profileID.uuidString,
                "record_id": recordID.uuidString,
                "byte_count": String(data.count),
                "retained_byte_count_before": String(record.standardError.count),
            ])
        record.standardError.append(data)
        if record.standardError.count > Self.maximumStandardErrorBytes {
            record.standardError.removeFirst(
                record.standardError.count - Self.maximumStandardErrorBytes)
        }

        let decoded = decodeAvailableUTF8(
            appending: data,
            remainder: &record.diagnosticRemainder)

        guard !decoded.isEmpty,
            let turn = activeTurn,
            turn.profileID == profileID,
            turn.recordID == recordID
        else {
            return
        }
        diagnostics.record(
            category: .acp,
            event: "acp_runner.diagnostic_event_forwarded",
            fields: [
                "profile_id": profileID.uuidString,
                "record_id": recordID.uuidString,
                "character_count": String(decoded.count),
            ])
        admit(
            .diagnostic(decoded),
            turnToken: turn.token,
            profileID: profileID,
            recordID: recordID)
    }

    private func finishedDiagnostics(profileID: UUID, recordID: UUID) {
        guard let record = records[profileID], record.id == recordID else {
            return
        }
        guard !record.diagnosticRemainder.isEmpty else {
            diagnostics.record(
                category: .acp,
                event: "acp_runner.standard_error_finished",
                fields: [
                    "profile_id": profileID.uuidString,
                    "record_id": recordID.uuidString,
                    "remainder_byte_count": "0",
                ])
            return
        }
        let decoded = String(decoding: record.diagnosticRemainder, as: UTF8.self)
        record.diagnosticRemainder.removeAll(keepingCapacity: true)
        guard let turn = activeTurn,
            turn.profileID == profileID,
            turn.recordID == recordID
        else {
            return
        }
        admit(
            .diagnostic(decoded),
            turnToken: turn.token,
            profileID: profileID,
            recordID: recordID)
    }

    private func markProcessExited(status: Int32, profileID: UUID, recordID: UUID) async -> Bool {
        guard let record = records[profileID], record.id == recordID else {
            return false
        }
        record.exitStatus = status
        diagnostics.record(
            category: .acp,
            event: "acp_runner.process_exited",
            level: status == 0 ? .info : .error,
            fields: [
                "profile_id": profileID.uuidString,
                "record_id": recordID.uuidString,
                "termination_status": String(status),
            ])
        await record.exitObservation.resolve()

        return true
    }

    private func processDrained(profileID: UUID, recordID: UUID) async {
        guard let record = records[profileID], record.id == recordID else {
            return
        }
        if let connection = record.connection {
            await connection.waitForInputCompletion()
        }

        guard records[profileID]?.id == recordID else {
            return
        }
        if !record.suppressesExitDiagnostic,
            let status = record.exitStatus,
            status != 0,
            let turn = activeTurn,
            turn.profileID == profileID,
            turn.recordID == recordID
        {
            admit(
                .diagnostic("Agent process exited with status \(status)."),
                turnToken: turn.token,
                profileID: profileID,
                recordID: recordID)
        }
        records.removeValue(forKey: profileID)
        diagnostics.record(
            category: .acp,
            event: "acp_runner.process_drained",
            fields: [
                "profile_id": profileID.uuidString,
                "record_id": recordID.uuidString,
                "termination_status": String(record.exitStatus ?? -1),
                "retained_standard_error_bytes": String(record.standardError.count),
            ])
    }

    private func raceDrain(transport: any ACPTransport) async -> ACPAgentDrainRace {
        await withTaskGroup(of: ACPAgentDrainRace.self) { group in
            group.addTask {
                await transport.waitForDrain()
                return .drained
            }
            group.addTask { [drainClock] in
                await drainClock.sleep(for: Self.exitDrainGracePeriod)
                return .deadline
            }
            let result = await group.next() ?? .deadline
            group.cancelAll()
            return result
        }
    }

    private func processExitWasObservedDuringPromptSettlement(
        record: ACPAgentConnectionRecord
    ) async -> Bool {
        let exitObservation = record.exitObservation
        let result = await withTaskGroup(of: ACPAgentPromptSettleRace.self) { group in
            group.addTask {
                switch await exitObservation.wait() {
                case .processExited:
                    return .processExited
                case .cancelled:
                    return .cancelled
                }
            }
            group.addTask { [settleClock] in
                await settleClock.sleep(for: Self.promptSettlePeriod)
                return .settled
            }
            let result = await group.next() ?? .settled
            group.cancelAll()
            return result
        }
        if case .processExited = result {
            return true
        }
        if record.exitStatus != nil {
            return true
        }
        return await exitObservation.isResolved()
    }

    func retainedStandardErrorByteCountForTesting(profileID: UUID) -> Int {
        records[profileID]?.standardError.count ?? 0
    }

    func pendingDiagnosticByteCountForTesting() -> Int {
        activeTurn?.delivery.snapshotForTesting.pendingDiagnosticBytes ?? 0
    }

    func eventDeliverySnapshotForTesting() -> AgentRunEventDeliverySnapshot? {
        activeTurn?.delivery.snapshotForTesting
    }

    private func forward(
        event: AgentRunEvent,
        turnToken: UUID,
        profileID: UUID,
        recordID: UUID
    ) {
        guard let turn = activeTurn,
            turn.token == turnToken,
            turn.profileID == profileID,
            turn.recordID == recordID,
            records[profileID]?.id == recordID
        else {
            diagnostics.record(
                category: .agent,
                event: "acp_runner.event_discarded",
                level: .debug,
                fields: [
                    "turn_id": turnToken.uuidString,
                    "profile_id": profileID.uuidString,
                    "record_id": recordID.uuidString,
                    "event_kind": event.runnerDiagnosticName,
                ])
            return
        }
        diagnostics.record(
            category: .agent,
            event: "acp_runner.event_received",
            fields: [
                "turn_id": turnToken.uuidString,
                "profile_id": profileID.uuidString,
                "record_id": recordID.uuidString,
                "event_kind": event.runnerDiagnosticName,
            ])
        admit(
            event,
            turnToken: turnToken,
            profileID: profileID,
            recordID: recordID)
    }

    private func publishSessionNotice(_ summary: String, turnToken: UUID) throws {
        guard var turn = activeTurn, turn.token == turnToken else {
            throw ACPAgentRunnerError.cancelled
        }
        switch turn.delivery.send(
            .metadata(
                kind: AgentRunMetadataKind.sessionRecovered,
                summary: summary))
        {
        case .accepted, .ignored, .stopped:
            return
        case .capacityExceeded, .invalid:
            turn.deliveryOverflowed = true
            activeTurn = turn
            throw ACPAgentRunnerError.eventDeliveryOverflow
        }
    }

    private func admit(
        _ event: AgentRunEvent,
        turnToken: UUID,
        profileID: UUID,
        recordID: UUID
    ) {
        guard let turn = activeTurn,
            turn.token == turnToken,
            turn.profileID == profileID,
            turn.recordID == recordID,
            records[profileID]?.id == recordID
        else {
            return
        }
        switch turn.delivery.send(event) {
        case .accepted:
            diagnostics.record(
                category: .agent,
                event: "acp_runner.event_admitted",
                level: .debug,
                fields: [
                    "turn_id": turnToken.uuidString,
                    "event_kind": event.runnerDiagnosticName,
                ])
            return
        case .ignored, .stopped:
            diagnostics.record(
                category: .agent,
                event: "acp_runner.event_not_admitted",
                level: .debug,
                fields: [
                    "turn_id": turnToken.uuidString,
                    "event_kind": event.runnerDiagnosticName,
                    "reason": "ignored_or_stopped",
                ])
            return
        case .capacityExceeded, .invalid:
            guard !turn.deliveryOverflowed else {
                return
            }
            var failedTurn = turn
            failedTurn.deliveryOverflowed = true
            activeTurn = failedTurn
            diagnostics.record(
                category: .agent,
                event: "acp_runner.event_delivery_overflowed",
                level: .error,
                fields: [
                    "turn_id": turnToken.uuidString,
                    "event_kind": event.runnerDiagnosticName,
                ])
            Task {
                await self.failOverflowedDelivery(turnToken: turnToken)
            }
        }
    }

    private func failOverflowedDelivery(turnToken: UUID) async {
        guard let turn = activeTurn,
            turn.token == turnToken,
            let connection = turn.connection
        else {
            return
        }
        await turn.delivery.finish(.drain)
        guard activeTurn?.token == turnToken else {
            return
        }
        await connection.close()
    }

    private func raceCancellation(
        completion: ACPAgentRunCompletionLatch
    ) async -> ACPAgentCancellationRace {
        await withTaskGroup(of: ACPAgentCancellationRace.self) { group in
            group.addTask {
                .completion(await completion.wait())
            }
            group.addTask { [clock] in
                await clock.sleep(for: Self.cancellationGracePeriod)
                return .deadline
            }
            let result = await group.next() ?? .deadline
            group.cancelAll()
            return result
        }
    }

    private func forceEvictActiveRecord(
        turnToken: UUID,
        profileID: UUID,
        capturedRecordID: UUID?
    ) async {
        guard let turn = activeTurn, turn.token == turnToken else {
            return
        }
        diagnostics.record(
            category: .agent,
            event: "acp_runner.active_session_force_eviction_started",
            level: .warning,
            fields: [
                "turn_id": turnToken.uuidString,
                "profile_id": profileID.uuidString,
            ])
        activeTurn = nil
        let recordID = capturedRecordID ?? turn.recordID
        guard let recordID,
            let record = records[profileID],
            record.id == recordID
        else {
            await turn.delivery.finish(.discard)
            return
        }

        records.removeValue(forKey: profileID)
        await turn.delivery.finish(.discard)
        await record.transport.terminate()
        await record.transport.closeReadStreams()
        record.diagnosticsTask?.cancel()
        record.exitTask?.cancel()
        if let connection = record.connection {
            Task {
                await connection.close()
            }
        }
    }

    private func discardRecord(
        profileID: UUID,
        recordID: UUID,
        fallbackRecord: ACPAgentConnectionRecord
    ) async {
        diagnostics.record(
            category: .agent,
            event: "acp_runner.session_discarding",
            fields: [
                "profile_id": profileID.uuidString,
                "record_id": recordID.uuidString,
            ])
        if records[profileID]?.id == recordID {
            records.removeValue(forKey: profileID)
            await dispose(fallbackRecord)
        } else {
            await fallbackRecord.transport.terminate()
        }
    }

    private func dispose(_ record: ACPAgentConnectionRecord) async {
        diagnostics.record(
            category: .agent,
            event: "acp_runner.session_disposal_started",
            fields: [
                "profile_id": record.profileID.uuidString,
                "record_id": record.id.uuidString,
            ])
        await record.transport.terminate()
        await record.transport.closeReadStreams()
        _ = await record.transport.waitForExit()
        await record.transport.waitForDrain()
        _ = await record.diagnosticsTask?.result
        _ = await record.exitTask?.result
        if let connection = record.connection {
            await connection.close()
        }
        diagnostics.record(
            category: .agent,
            event: "acp_runner.session_disposal_finished",
            fields: [
                "profile_id": record.profileID.uuidString,
                "record_id": record.id.uuidString,
                "termination_status": String(record.exitStatus ?? -1),
            ])
    }

    private func updateActiveTurnRecord(
        token: UUID,
        record: ACPAgentConnectionRecord
    ) {
        guard var turn = activeTurn, turn.token == token else {
            return
        }
        turn.recordID = record.id
        activeTurn = turn
    }

    private func updateActiveTurn(
        token: UUID,
        record: ACPAgentConnectionRecord,
        connection: ACPClientConnection
    ) {
        guard var turn = activeTurn, turn.token == token else {
            return
        }
        turn.recordID = record.id
        turn.connection = connection
        activeTurn = turn
    }

    private func clearActiveTurnConnection(token: UUID) {
        guard var turn = activeTurn, turn.token == token else {
            return
        }
        turn.recordID = nil
        turn.connection = nil
        activeTurn = turn
    }

    private func ownsActiveTurn(_ token: UUID) -> Bool {
        activeTurn?.token == token
    }

    private func isActiveTurnCancelling(_ token: UUID) -> Bool {
        guard let turn = activeTurn, turn.token == token else {
            return true
        }
        return turn.isCancelling
    }

    private func ensureActiveTurn(token: UUID) throws {
        guard ownsActiveTurn(token), !isActiveTurnCancelling(token) else {
            throw ACPAgentRunnerError.cancelled
        }
    }

    private func clearActiveTurn(token: UUID) {
        if activeTurn?.token == token {
            activeTurn = nil
        }
    }

    nonisolated private static func elapsedMilliseconds(since start: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= start else { return 0 }
        return (now - start) / 1_000_000
    }
}

extension AgentRunEvent {
    fileprivate var runnerDiagnosticName: String {
        switch self {
        case .connected: "connected"
        case .agentMessageDelta: "agent_message_delta"
        case .thoughtDelta: "thought_delta"
        case .toolCall: "tool_call"
        case .toolCallUpdate: "tool_call_update"
        case .plan: "plan"
        case .permissionRequested: "permission_requested"
        case .metadata: "metadata"
        case .diagnostic: "diagnostic"
        case .deliveryNotice: "delivery_notice"
        case .unknown: "unknown"
        }
    }
}

extension ACPClientError {
    fileprivate var isSessionUnavailable: Bool {
        if case .sessionUnavailable = self {
            return true
        }
        return false
    }
}

private final class ACPAgentConnectionRecord {
    let id: UUID
    let profileID: UUID
    let configuration: AgentHarnessConfiguration
    let transport: any ACPTransport
    var connection: ACPClientConnection?
    var diagnosticsTask: Task<Void, Never>?
    var exitTask: Task<Void, Never>?
    var standardError = Data()
    var diagnosticRemainder = Data()
    var exitStatus: Int32?
    var suppressesExitDiagnostic = false
    var accessOrdinal: UInt64
    let exitObservation: ACPAgentProcessExitLatch

    init(
        id: UUID,
        profileID: UUID,
        configuration: AgentHarnessConfiguration,
        transport: any ACPTransport,
        accessOrdinal: UInt64,
        beforeCancelledExitWaitReturns: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.profileID = profileID
        self.configuration = configuration
        self.transport = transport
        self.accessOrdinal = accessOrdinal
        exitObservation = ACPAgentProcessExitLatch(
            beforeCancelledWaitReturns: beforeCancelledExitWaitReturns)
    }
}

private struct ACPAgentActiveTurn {
    let token: UUID
    let profileID: UUID
    var recordID: UUID?
    var connection: ACPClientConnection?
    let completion: ACPAgentRunCompletionLatch
    let delivery: AgentRunEventDelivery
    var isCancelling: Bool
    var deliveryOverflowed: Bool
}

private enum ACPAgentRunCompletion: Sendable {
    case success(AgentRunResult)
    case failure
}

private enum ACPAgentCancellationRace: Sendable {
    case completion(ACPAgentRunCompletion)
    case deadline
}

private enum ACPAgentDrainRace: Sendable {
    case drained
    case deadline
}

private enum ACPAgentPromptSettleRace: Sendable {
    case processExited
    case settled
    case cancelled
}

private enum ACPAgentConnectionStartupOutcome: Sendable {
    case connected(ACPClientConnection)
    case failed(any Error)
    case cancelled
    case timedOut
}

private enum ACPAgentProcessExitWaitResult: Sendable {
    case processExited
    case cancelled
}

private actor ACPAgentProcessExitLatch {
    private var wasResolved = false
    private var waiters: [UUID: CheckedContinuation<ACPAgentProcessExitWaitResult, Never>] = [:]
    private let beforeCancelledWaitReturns: @Sendable () async -> Void

    init(beforeCancelledWaitReturns: @escaping @Sendable () async -> Void) {
        self.beforeCancelledWaitReturns = beforeCancelledWaitReturns
    }

    func resolve() {
        guard !wasResolved else {
            return
        }
        wasResolved = true
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: .processExited)
        }
    }

    func wait() async -> ACPAgentProcessExitWaitResult {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if wasResolved {
                    continuation.resume(returning: .processExited)
                } else if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func isResolved() -> Bool {
        wasResolved
    }

    private func cancelWaiter(id: UUID) async {
        guard let waiter = waiters.removeValue(forKey: id) else {
            return
        }
        await beforeCancelledWaitReturns()
        waiter.resume(returning: wasResolved ? .processExited : .cancelled)
    }
}

private actor ACPAgentRunCompletionLatch {
    private var value: ACPAgentRunCompletion?
    private var waiters: [UUID: CheckedContinuation<ACPAgentRunCompletion, Never>] = [:]

    func resolve(_ result: ACPAgentRunCompletion) {
        guard value == nil else {
            return
        }
        value = result
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: result)
        }
    }

    func wait() async -> ACPAgentRunCompletion {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let value {
                    continuation.resume(returning: value)
                } else if Task.isCancelled {
                    continuation.resume(returning: .failure)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func completedValue() -> ACPAgentRunCompletion? {
        value
    }

    private func cancelWaiter(id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: .failure)
    }
}

private func decodeAvailableUTF8(appending data: Data, remainder: inout Data) -> String {
    remainder.append(data)
    guard !remainder.isEmpty else {
        return ""
    }

    let incompleteCount = trailingIncompleteUTF8ByteCount(in: remainder)
    let readyCount = remainder.count - incompleteCount
    guard readyCount > 0 else {
        return ""
    }
    let ready = remainder.prefix(readyCount)
    if incompleteCount == 0 {
        remainder.removeAll(keepingCapacity: true)
    } else {
        remainder = Data(remainder.suffix(incompleteCount))
    }
    return String(decoding: ready, as: UTF8.self)
}

private func trailingIncompleteUTF8ByteCount(in data: Data) -> Int {
    let bytes = Array(data.suffix(4))
    guard !bytes.isEmpty else {
        return 0
    }

    var leadingIndex = bytes.count - 1
    while leadingIndex > 0, bytes[leadingIndex] & 0xC0 == 0x80 {
        leadingIndex -= 1
    }
    let leadingByte = bytes[leadingIndex]
    let expectedCount: Int
    switch leadingByte {
    case 0xC2...0xDF:
        expectedCount = 2
    case 0xE0...0xEF:
        expectedCount = 3
    case 0xF0...0xF4:
        expectedCount = 4
    default:
        return 0
    }
    let availableCount = bytes.count - leadingIndex
    return availableCount < expectedCount ? availableCount : 0
}

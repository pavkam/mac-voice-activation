// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

extension ACPAgentRunner {
    func connectionRecord(
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

    func connect(
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

    func evictLeastRecentlyUsedSessionIfNeeded(
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

    func recordSessionEviction(profileID: UUID) {
        evictedProfileIDs.removeAll { $0 == profileID }
        evictedProfileIDs.append(profileID)
        if evictedProfileIDs.count > Self.maximumTrackedSessionEvictions {
            evictedProfileIDs.removeFirst(
                evictedProfileIDs.count - Self.maximumTrackedSessionEvictions)
        }
    }

    func markAccessed(_ record: ACPAgentConnectionRecord) {
        record.accessOrdinal = nextAccessOrdinal()
    }

    func nextAccessOrdinal() -> UInt64 {
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

    func startObservers(for record: ACPAgentConnectionRecord) async {
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

    func receivedDiagnostic(_ data: Data, profileID: UUID, recordID: UUID) {
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

    func finishedDiagnostics(profileID: UUID, recordID: UUID) {
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

    func markProcessExited(status: Int32, profileID: UUID, recordID: UUID) async -> Bool {
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

    func processDrained(profileID: UUID, recordID: UUID) async {
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

    func raceDrain(transport: any ACPTransport) async -> ACPAgentDrainRace {
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

    func processExitWasObservedDuringPromptSettlement(
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

}

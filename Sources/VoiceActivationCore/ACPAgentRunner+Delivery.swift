// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

extension ACPAgentRunner {
    func retainedStandardErrorByteCountForTesting(profileID: UUID) -> Int {
        records[profileID]?.standardError.count ?? 0
    }

    func pendingDiagnosticByteCountForTesting() -> Int {
        activeTurn?.delivery.snapshotForTesting.pendingDiagnosticBytes ?? 0
    }

    func eventDeliverySnapshotForTesting() -> AgentRunEventDeliverySnapshot? {
        activeTurn?.delivery.snapshotForTesting
    }

    func forward(
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

    func publishSessionNotice(_ summary: String, turnToken: UUID) throws {
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

    func admit(
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
                    "task_priority": String(Task.currentPriority.rawValue),
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

    func failOverflowedDelivery(turnToken: UUID) async {
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

    func raceCancellation(
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

    func forceEvictActiveRecord(
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

    func discardRecord(
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

    func dispose(_ record: ACPAgentConnectionRecord) async {
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

    func updateActiveTurnRecord(
        token: UUID,
        record: ACPAgentConnectionRecord
    ) {
        guard var turn = activeTurn, turn.token == token else {
            return
        }
        turn.recordID = record.id
        activeTurn = turn
    }

    func updateActiveTurn(
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

    func clearActiveTurnConnection(token: UUID) {
        guard var turn = activeTurn, turn.token == token else {
            return
        }
        turn.recordID = nil
        turn.connection = nil
        activeTurn = turn
    }

    func ownsActiveTurn(_ token: UUID) -> Bool {
        activeTurn?.token == token
    }

    func isActiveTurnCancelling(_ token: UUID) -> Bool {
        guard let turn = activeTurn, turn.token == token else {
            return true
        }
        return turn.isCancelling
    }

    func ensureActiveTurn(token: UUID) throws {
        guard ownsActiveTurn(token), !isActiveTurnCancelling(token) else {
            throw ACPAgentRunnerError.cancelled
        }
    }

    func clearActiveTurn(token: UUID) {
        if activeTurn?.token == token {
            activeTurn = nil
        }
    }

    nonisolated static func elapsedMilliseconds(since start: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= start else { return 0 }
        return (now - start) / 1_000_000
    }
}

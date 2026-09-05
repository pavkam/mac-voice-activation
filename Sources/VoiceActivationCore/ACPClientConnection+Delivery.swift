// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

extension ACPClientConnection {

    func sendResponse(id: ACPRequestID, result: ACPJSONValue) async {
        do {
            try await write(
                .response(id: id, result: result),
                allowWhileClosing: true)
        } catch {
            finalize(with: .connectionClosed)
            await terminateTransport()
        }
    }

    func sendErrorResponse(id: ACPRequestID, code: Int64, message: String) async {
        do {
            try await write(
                .errorResponse(
                    id: id,
                    error: ACPJSONRPCError(code: code, message: message)),
                allowWhileClosing: true)
        } catch {
            finalize(with: .connectionClosed)
            await terminateTransport()
        }
    }

    func sendNotification(method: String, params: ACPJSONValue?) async {
        do {
            try await write(.notification(method: method, params: params))
        } catch {
            finalize(with: .connectionClosed)
            await terminateTransport()
        }
    }

    func write(
        _ message: ACPMessage,
        allowWhileClosing: Bool = false
    ) async throws {
        await acquireWritePermit()
        defer { releaseWritePermit() }
        if allowWhileClosing {
            if let terminalError {
                throw terminalError
            }
        } else {
            try ensureOpen()
        }

        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        diagnostics.record(
            category: .acp,
            event: "acp_client.message_sending",
            level: .debug,
            fields: [
                "connection_id": connectionID.uuidString,
                "message_kind": message.clientDiagnosticKind,
                "method": message.clientDiagnosticMethod ?? "",
                "byte_count": String(data.count),
                "waiting_writer_count": String(max(0, writeWaiters.count - writeWaiterHead)),
            ])
        try await transport.send(data)
        diagnostics.record(
            category: .acp,
            event: "acp_client.message_sent",
            level: .debug,
            fields: [
                "connection_id": connectionID.uuidString,
                "message_kind": message.clientDiagnosticKind,
                "method": message.clientDiagnosticMethod ?? "",
                "byte_count": String(data.count),
            ])
    }

    func acquireWritePermit() async {
        if !writeIsActive {
            writeIsActive = true
            return
        }

        diagnostics.record(
            category: .acp,
            event: "acp_client.writer_waiting",
            level: .debug,
            fields: [
                "connection_id": connectionID.uuidString,
                "waiting_writer_count": String(max(0, writeWaiters.count - writeWaiterHead) + 1),
            ])
        await withCheckedContinuation { continuation in
            writeWaiters.append(continuation)
        }
    }

    func releaseWritePermit() {
        if writeWaiterHead == writeWaiters.count {
            writeWaiters.removeAll(keepingCapacity: true)
            writeWaiterHead = 0
            writeIsActive = false
        } else {
            let waiter = writeWaiters[writeWaiterHead]
            writeWaiterHead += 1
            if writeWaiterHead >= 128, writeWaiterHead * 2 >= writeWaiters.count {
                writeWaiters.removeSubrange(0..<writeWaiterHead)
                writeWaiterHead = 0
            }
            waiter.resume()
        }
    }

    func deliver(_ event: AgentRunEvent) async throws {
        guard let delivery = activeEventDelivery else {
            diagnostics.record(
                category: .agent,
                event: "acp_client.event_dropped",
                level: .debug,
                fields: [
                    "connection_id": connectionID.uuidString,
                    "event_kind": event.clientDiagnosticName,
                    "reason": "no_active_delivery",
                ])
            return
        }
        switch delivery.send(event) {
        case .accepted:
            diagnostics.record(
                category: .agent,
                event: "acp_client.event_delivered",
                level: .debug,
                fields: [
                    "connection_id": connectionID.uuidString,
                    "event_kind": event.clientDiagnosticName,
                ])
            return
        case .ignored, .stopped:
            diagnostics.record(
                category: .agent,
                event: "acp_client.event_dropped",
                level: .debug,
                fields: [
                    "connection_id": connectionID.uuidString,
                    "event_kind": event.clientDiagnosticName,
                    "reason": "ignored_or_stopped",
                ])
            return
        case .capacityExceeded, .invalid:
            diagnostics.record(
                category: .agent,
                event: "acp_client.event_delivery_overflowed",
                level: .error,
                fields: [
                    "connection_id": connectionID.uuidString,
                    "event_kind": event.clientDiagnosticName,
                ])
            await delivery.finish(.drain)
            throw ACPClientError.eventDeliveryOverflow
        }
    }

    func finishTurn(turnToken: AgentTurnToken) {
        guard activeTurnToken == turnToken else {
            return
        }

        let stalePermissions = pendingPermissions.keys.filter {
            $0.turnToken == turnToken
        }
        for key in stalePermissions {
            pendingPermissions.removeValue(forKey: key)
        }
        activeEventDelivery = nil
        activeTurnToken = nil
        activePromptRequestID = nil
        promptFrameWasPublished = false
        promptResponseWasReceived = false
        promptHadActivity = false
        isPromptCancelling = false
        cancelFrameWasSent = false
        diagnostics.record(
            category: .acp,
            event: "acp_client.turn_state_cleared",
            fields: [
                "connection_id": connectionID.uuidString,
                "stale_permission_count": String(stalePermissions.count),
            ])
    }

    func ensureOpen() throws {
        if let terminalError {
            throw terminalError
        }
        if isClosing {
            throw ACPClientError.connectionClosed
        }
    }

    func finalize(with error: ACPClientError) {
        guard terminalError == nil else {
            return
        }

        terminalError = error
        let requests = pendingRequests
        pendingRequests.removeAll()
        pendingRequestMethods.removeAll()
        pendingRequestStartedAt.removeAll()
        diagnostics.record(
            category: .acp,
            event: "acp_client.finalized",
            level: .error,
            fields: [
                "connection_id": connectionID.uuidString,
                "pending_request_count": String(requests.count),
                "error_type": String(describing: type(of: error)),
            ])
        for pending in requests.values {
            if let continuation = pending.continuation {
                continuation.resume(throwing: error)
            }
        }
    }

    func terminateTransport() async {
        guard !transportWasTerminated else {
            return
        }
        transportWasTerminated = true
        diagnostics.record(
            category: .acp,
            event: "acp_client.transport_terminating",
            fields: ["connection_id": connectionID.uuidString])
        await transport.terminate()
    }

    func userSafeError(_ error: any Error) -> ACPClientError {
        if let clientError = error as? ACPClientError {
            return clientError
        }
        return terminalError ?? .connectionClosed
    }

    nonisolated static func elapsedMilliseconds(since start: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= start else { return 0 }
        return (now - start) / 1_000_000
    }
}

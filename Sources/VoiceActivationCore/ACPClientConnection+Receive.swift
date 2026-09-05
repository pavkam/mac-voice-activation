// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

extension ACPClientConnection {
    func receive(_ output: AsyncThrowingStream<Data, any Error>) async {
        var framer = ACPLineFramer()
        diagnostics.record(
            category: .acp,
            event: "acp_client.receive_started",
            fields: ["connection_id": connectionID.uuidString])

        var receiveFailure = ACPClientError.connectionClosed
        do {
            for try await chunk in output {
                if Task.isCancelled {
                    return
                }

                let frames = try framer.append(chunk)
                diagnostics.record(
                    category: .acp,
                    event: "acp_client.output_chunk_received",
                    level: .debug,
                    fields: [
                        "connection_id": connectionID.uuidString,
                        "byte_count": String(chunk.count),
                        "frame_count": String(frames.count),
                    ])
                for frame in frames {
                    let message = try JSONDecoder().decode(ACPMessage.self, from: frame)
                    try await handle(message)
                }
            }
            try framer.finish()
        } catch {
            receiveFailure = userSafeError(error)
            diagnostics.record(
                category: .acp,
                event: "acp_client.receive_failed",
                level: .error,
                fields: [
                    "connection_id": connectionID.uuidString,
                    "error_type": String(describing: type(of: error)),
                ])
        }

        guard terminalError == nil else {
            return
        }
        finalize(with: receiveFailure)
        diagnostics.record(
            category: .acp,
            event: "acp_client.receive_finished",
            fields: ["connection_id": connectionID.uuidString])
        await terminateTransport()
    }

    func handle(_ message: ACPMessage) async throws {
        diagnostics.record(
            category: .acp,
            event: "acp_client.message_received",
            level: .debug,
            fields: [
                "connection_id": connectionID.uuidString,
                "message_kind": message.clientDiagnosticKind,
                "method": message.clientDiagnosticMethod ?? "",
            ])
        switch message {
        case .response(let id, let result):
            try await completePendingRequest(id: id, result: .success(result))
        case .errorResponse(let id, let error):
            let message = boundedText(
                error.message,
                maximumBytes: Self.maximumDiagnosticBytes)
            try await completePendingRequest(
                id: id,
                result: .failure(
                    ACPRemoteErrorClassifier.clientError(
                        for: error,
                        safeMessage: message,
                        isPromptResponse: id == activePromptRequestID,
                        promptHadActivity: promptHadActivity)))
        case .request(let id, let method, let params):
            if activeTurnToken != nil, !promptResponseWasReceived {
                promptHadActivity = true
            }
            try await handleRequest(id: id, method: method, params: params)
        case .notification(let method, let params):
            if method == "session/update" {
                guard try sessionUpdateBelongsToActiveSession(params) else {
                    try await deliver(
                        .diagnostic(
                            boundedText(
                                "Ignored ACP update for a different session.",
                                maximumBytes: Self.maximumDiagnosticBytes)))
                    return
                }
                if activeTurnToken != nil, !promptResponseWasReceived {
                    promptHadActivity = true
                }
                if let event = try eventDecoder.event(from: message) {
                    try await deliver(event)
                }
            } else {
                if activeTurnToken != nil, !promptResponseWasReceived {
                    promptHadActivity = true
                }
                try await deliver(
                    .diagnostic(
                        boundedText(
                            "Unsupported ACP notification: \(method)",
                            maximumBytes: Self.maximumDiagnosticBytes)))
            }
        }
    }

    func sessionUpdateBelongsToActiveSession(_ params: ACPJSONValue?) throws -> Bool {
        let parameters = try requiredObject(params, named: "session/update params")
        let updateSessionID = try requiredString(
            parameters["sessionId"],
            named: "session/update sessionId")
        guard updateSessionID.utf8.count <= ACPEventDecoder.maximumOpaqueIdentifierBytes else {
            throw ACPClientError.malformedResponse(
                "session/update sessionId exceeds the opaque identifier limit.")
        }
        return updateSessionID == sessionID
    }

    func completePendingRequest(
        id: ACPRequestID,
        result: PendingClientRequest.Result
    ) async throws {
        guard var pending = pendingRequests[id], pending.bufferedResult == nil else {
            diagnostics.record(
                category: .acp,
                event: "acp_client.response_ignored",
                level: .warning,
                fields: [
                    "connection_id": connectionID.uuidString,
                    "request_id": requestIDDescription(id),
                    "reason": "unknown_or_duplicate",
                ])
            try await deliver(
                .diagnostic(
                    boundedText(
                        "Ignored unknown response for request \(requestIDDescription(id)).",
                        maximumBytes: Self.maximumDiagnosticBytes)))
            return
        }

        let method = pendingRequestMethods.removeValue(forKey: id) ?? "unknown"
        let startedAt = pendingRequestStartedAt.removeValue(forKey: id)
        diagnostics.record(
            category: .acp,
            event: "acp_client.response_received",
            level: result.isFailure ? .error : .info,
            fields: [
                "connection_id": connectionID.uuidString,
                "request_id": requestIDDescription(id),
                "method": method,
                "outcome": result.isFailure ? "failure" : "success",
                "duration_ms": startedAt.map {
                    String(Self.elapsedMilliseconds(since: $0))
                } ?? "unknown",
            ])

        if id == activePromptRequestID {
            promptResponseWasReceived = true
            activeEventDelivery?.stopAdmission()
            await cancelPendingPermissions()
        }

        if let continuation = pending.continuation {
            pendingRequests.removeValue(forKey: id)
            resume(continuation, with: result)
        } else {
            pending.bufferedResult = result
            pendingRequests[id] = pending
        }
    }

    func handleRequest(
        id: ACPRequestID,
        method: String,
        params: ACPJSONValue?
    ) async throws {
        diagnostics.record(
            category: .acp,
            event: "acp_client.server_request_received",
            fields: [
                "connection_id": connectionID.uuidString,
                "request_id": requestIDDescription(id),
                "method": method,
            ])
        switch method {
        case "session/request_permission":
            do {
                try await handlePermissionRequest(id: id, params: params)
            } catch PermissionRequestError.oversized {
                await sendResponse(id: id, result: permissionCancellation())
            } catch {
                await sendErrorResponse(
                    id: id,
                    code: -32_602,
                    message: "Invalid params")
            }
        case "cursor/ask_question", "cursor/create_plan":
            await sendResponse(id: id, result: permissionCancellation())
            try await deliver(
                .diagnostic(
                    boundedText(
                        "Cancelled unsupported blocking extension: \(method)",
                        maximumBytes: Self.maximumDiagnosticBytes)))
        default:
            await sendErrorResponse(
                id: id,
                code: -32_601,
                message: "Method not found")
        }
    }

    func handlePermissionRequest(
        id: ACPRequestID,
        params: ACPJSONValue?
    ) async throws {
        if case .string(let identifier) = id,
            identifier.utf8.count > ACPEventDecoder.maximumOpaqueIdentifierBytes
        {
            throw PermissionRequestError.oversized
        }
        let decoded = try decodePermissionRequest(params: params)
        guard decoded.sessionID == sessionID,
            let turnToken = activeTurnToken,
            !promptResponseWasReceived
        else {
            await sendResponse(id: id, result: permissionCancellation())
            return
        }
        let request = AgentPermissionRequest(
            turnToken: turnToken,
            requestID: id,
            toolCall: decoded.toolCall,
            options: decoded.options)
        diagnostics.record(
            category: .acp,
            event: "acp_client.permission_received",
            fields: [
                "connection_id": connectionID.uuidString,
                "option_count": String(request.options.count),
                "policy": configuration.permissionPolicy.rawValue,
            ])
        guard
            permissionRetainedByteCount(request)
                <= AgentRunEventDelivery.maximumPendingControlBytes
        else {
            throw PermissionRequestError.oversized
        }
        let key = PendingPermissionKey(turnToken: turnToken, requestID: id)
        guard pendingPermissions[key] == nil else {
            try await deliver(
                .diagnostic(
                    boundedText(
                        "Ignored duplicate permission request \(requestIDDescription(id)).",
                        maximumBytes: Self.maximumDiagnosticBytes)))
            return
        }
        if isPromptCancelling {
            await sendResponse(id: id, result: permissionCancellation())
            return
        }
        switch configuration.permissionPolicy {
        case .ask:
            guard pendingPermissions.count < Self.maximumPendingPermissions else {
                await sendResponse(id: id, result: permissionCancellation())
                return
            }
            pendingPermissions[key] = PendingPermission(options: request.options)
            diagnostics.record(
                category: .acp,
                event: "acp_client.permission_queued_for_user",
                fields: [
                    "connection_id": connectionID.uuidString,
                    "pending_permission_count": String(pendingPermissions.count),
                ])
            try await deliver(.permissionRequested(request))
        case .allowOnce:
            let selection =
                request.options.first(where: { $0.kind == .allowOnce })
                ?? request.options.first(where: { $0.kind == .allowAlways })
            if let selection {
                await sendResponse(id: id, result: permissionSelection(optionID: selection.id))
            } else {
                await sendResponse(id: id, result: permissionCancellation())
            }
        case .allowAlways:
            let selection =
                request.options.first(where: { $0.kind == .allowAlways })
                ?? request.options.first(where: { $0.kind == .allowOnce })
            if let selection {
                await sendResponse(id: id, result: permissionSelection(optionID: selection.id))
            } else {
                await sendResponse(id: id, result: permissionCancellation())
            }
        case .reject:
            if let selection = request.options.first(where: { $0.kind == .rejectOnce }) {
                await sendResponse(id: id, result: permissionSelection(optionID: selection.id))
            } else {
                await sendResponse(id: id, result: permissionCancellation())
            }
        case .rejectAlways:
            let selection =
                request.options.first(where: { $0.kind == .rejectAlways })
                ?? request.options.first(where: { $0.kind == .rejectOnce })
            if let selection {
                await sendResponse(id: id, result: permissionSelection(optionID: selection.id))
            } else {
                await sendResponse(id: id, result: permissionCancellation())
            }
        }
    }

    func systemInstruction() -> String {
        guard !configuration.systemPrompt.isEmpty, configuration.preset != .codex else {
            return Self.markdownPresentationInstruction
        }
        return """
            \(Self.markdownPresentationPreamble)

            Profile-specific system instruction:
            \(configuration.systemPrompt)

            The following content block is the user's request.
            """
    }

    func decodePermissionRequest(
        params: ACPJSONValue?
    ) throws -> DecodedPermissionRequest {
        let parameters = try requiredObject(params, named: "permission params")
        let permissionSessionID = try requiredOpaqueString(
            parameters["sessionId"],
            named: "permission sessionId")
        let toolValue = try requiredObject(
            parameters["toolCall"],
            named: "permission toolCall")
        let toolCall = AgentToolCallUpdate(
            id: try requiredOpaqueString(toolValue["toolCallId"], named: "toolCallId"),
            title: try optionalString(toolValue["title"], named: "toolCall title"),
            kind: try optionalRawValue(toolValue["kind"], named: "toolCall kind"),
            status: try optionalRawValue(toolValue["status"], named: "toolCall status"))
        let optionValues = try requiredArray(
            parameters["options"],
            named: "permission options")
        guard optionValues.count <= AgentRunEventDelivery.maximumPermissionOptions else {
            throw PermissionRequestError.oversized
        }
        let options = try optionValues.map { optionValue in
            let option = try requiredObject(optionValue, named: "permission option")
            return AgentPermissionOption(
                id: try requiredOpaqueString(
                    option["optionId"],
                    named: "permission optionId"),
                label: try requiredString(option["name"], named: "permission name"),
                kind: try requiredRawValue(option["kind"], named: "permission kind"))
        }

        let retainedBytes =
            toolCall.id.utf8.count
            + (toolCall.title?.utf8.count ?? 0)
            + options.reduce(0) { partial, option in
                saturatingByteCount(
                    saturatingByteCount(partial, option.id.utf8.count),
                    option.label.utf8.count)
            }
        guard retainedBytes <= AgentRunEventDelivery.maximumPendingControlBytes else {
            throw PermissionRequestError.oversized
        }

        return DecodedPermissionRequest(
            sessionID: permissionSessionID,
            toolCall: toolCall,
            options: options)
    }

    func cancelPendingPermissions() async {
        let permissions = pendingPermissions
        pendingPermissions.removeAll()
        if !permissions.isEmpty {
            diagnostics.record(
                category: .acp,
                event: "acp_client.pending_permissions_cancelled",
                fields: [
                    "connection_id": connectionID.uuidString,
                    "count": String(permissions.count),
                ])
        }
        for key in permissions.keys {
            await sendResponse(id: key.requestID, result: permissionCancellation())
        }
    }

    func sendCancelIfPromptWasPublished() async {
        guard isPromptCancelling,
            promptFrameWasPublished,
            !promptResponseWasReceived,
            !cancelFrameWasSent,
            let sessionID
        else {
            return
        }

        cancelFrameWasSent = true
        diagnostics.record(
            category: .acp,
            event: "acp_client.cancel_frame_sending",
            fields: ["connection_id": connectionID.uuidString])
        await sendNotification(
            method: "session/cancel",
            params: .object(["sessionId": .string(sessionID)]))
    }
}

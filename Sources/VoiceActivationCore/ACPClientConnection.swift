// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

public enum ACPClientError: Error, Equatable, LocalizedError, Sendable {
    case connectionClosed
    case incompatibleProtocol(selected: Int64)
    case authenticationRequired(methods: [String])
    case promptTooLarge(maximumBytes: Int)
    case promptAlreadyActive
    case eventDeliveryOverflow
    case malformedResponse(String)
    case sessionUnavailable(code: Int64, message: String)
    case remoteError(code: Int64, message: String)

    public var errorDescription: String? {
        switch self {
        case .connectionClosed:
            "The agent connection closed unexpectedly."
        case .incompatibleProtocol(let selected):
            "The agent selected unsupported ACP protocol version \(selected)."
        case .authenticationRequired(let methods):
            if methods.isEmpty {
                "Authenticate with the provider CLI, then try again."
            } else {
                "Authenticate with the provider CLI, then try again. Available methods: "
                    + methods.joined(separator: ", ")
            }
        case .promptTooLarge(let maximumBytes):
            "The prompt exceeds the \(maximumBytes)-byte UTF-8 limit."
        case .promptAlreadyActive:
            "An agent prompt is already active on this connection."
        case .eventDeliveryOverflow:
            "The agent produced more control events than can be delivered safely."
        case .malformedResponse(let description):
            "The agent sent an invalid ACP response: \(description)"
        case .sessionUnavailable(let code, let message):
            "The agent session is no longer available (\(code)): \(message)"
        case .remoteError(let code, let message):
            "The agent request failed (\(code)): \(message)"
        }
    }
}

public actor ACPClientConnection {
    public static let maximumPromptBytes = 8_192
    public static let maximumDiagnosticBytes = 256
    public static let maximumPendingPermissions = 32

    private static let maximumAdvertisedAuthenticationMethods = 8
    private static let clientName = "voice-activation"
    private static let clientTitle = "Voice Activation"
    private static let clientVersion = "0.1.0"
    private static let markdownPresentationPreamble = """
        System instruction from Voice Activation:
        \(ACPAgentInstruction.responseStyle)
        """
    static let markdownPresentationInstruction = """
        \(markdownPresentationPreamble)
        The following content block is the user's request.
        """

    private let transport: any ACPTransport
    private let configuration: AgentHarnessConfiguration
    private let diagnostics: any VoiceActivationDiagnosticRecording
    private let connectionID = UUID()
    private let eventDecoder = ACPEventDecoder()
    private var receiveTask: Task<Void, Never>?
    private var nextRequestID: Int64 = 1
    private var pendingRequests: [ACPRequestID: PendingClientRequest] = [:]
    private var pendingRequestMethods: [ACPRequestID: String] = [:]
    private var pendingRequestStartedAt: [ACPRequestID: UInt64] = [:]
    private var pendingPermissions: [PendingPermissionKey: PendingPermission] = [:]
    private var authenticationMethodNames: [String] = []
    private var sessionID: String?
    private var agentName: String?
    private var activeEventDelivery: AgentRunEventDelivery?
    private var activeTurnToken: AgentTurnToken?
    private var activePromptRequestID: ACPRequestID?
    private var promptFrameWasPublished = false
    private var promptResponseWasReceived = false
    private var promptHadActivity = false
    private var isPromptCancelling = false
    private var cancelFrameWasSent = false
    private var terminalError: ACPClientError?
    private var transportWasTerminated = false
    private var isClosing = false
    private let closeCompletion = ACPClientCloseCompletion()
    private var writeIsActive = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeWaiterHead = 0

    private init(
        transport: any ACPTransport,
        configuration: AgentHarnessConfiguration,
        diagnostics: any VoiceActivationDiagnosticRecording
    ) {
        self.transport = transport
        self.configuration = configuration
        self.diagnostics = diagnostics
    }

    public static func connect(
        transport: any ACPTransport,
        configuration: AgentHarnessConfiguration,
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    )
        async throws -> ACPClientConnection
    {
        let connection = ACPClientConnection(
            transport: transport,
            configuration: configuration,
            diagnostics: diagnostics)
        try await connection.start()
        return connection
    }

    public func prompt(
        _ prompt: String,
        onEvent: @escaping @Sendable (AgentRunEvent) async -> Void
    ) async throws -> AgentRunResult {
        let promptStartedAt = DispatchTime.now().uptimeNanoseconds
        diagnostics.record(
            category: .acp,
            event: "acp_client.prompt_started",
            fields: [
                "connection_id": connectionID.uuidString,
                "input_character_count": String(prompt.count),
                "has_session": String(sessionID != nil),
            ])
        guard prompt.utf8.count <= Self.maximumPromptBytes else {
            diagnostics.record(
                category: .acp,
                event: "acp_client.prompt_rejected",
                level: .warning,
                fields: [
                    "connection_id": connectionID.uuidString,
                    "reason": "too_large",
                    "input_byte_count": String(prompt.utf8.count),
                ])
            throw ACPClientError.promptTooLarge(maximumBytes: Self.maximumPromptBytes)
        }
        try ensureOpen()
        guard activeTurnToken == nil else {
            throw ACPClientError.promptAlreadyActive
        }
        guard let sessionID, let agentName else {
            throw ACPClientError.malformedResponse("The session is not initialized.")
        }

        let turnToken = AgentTurnToken()
        let eventDelivery = AgentRunEventDelivery(handler: onEvent)
        activeTurnToken = turnToken
        activeEventDelivery = eventDelivery
        activePromptRequestID = nil
        promptFrameWasPublished = false
        promptResponseWasReceived = false
        promptHadActivity = false
        isPromptCancelling = false
        cancelFrameWasSent = false
        do {
            guard
                eventDelivery.send(.connected(agentName: agentName, sessionID: sessionID))
                    == .accepted
            else {
                throw ACPClientError.eventDeliveryOverflow
            }
            let result = try await sendPromptRequest(
                params: .object([
                    "sessionId": .string(sessionID),
                    "prompt": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string(systemInstruction()),
                        ]),
                        .object([
                            "type": .string("text"),
                            "text": .string(prompt),
                        ]),
                    ]),
                ]))
            let object = try requiredObject(result, named: "session/prompt result")
            let encodedReason = try requiredString(
                object["stopReason"],
                named: "stopReason")
            guard let stopReason = AgentStopReason(rawValue: encodedReason) else {
                throw ACPClientError.malformedResponse("Unknown stopReason.")
            }
            guard !isPromptCancelling || stopReason == .cancelled else {
                throw ACPClientError.malformedResponse(
                    "A cancelled prompt returned a non-cancelled stopReason.")
            }

            await eventDelivery.finish(.drain)
            guard activeTurnToken == turnToken else {
                throw terminalError ?? ACPClientError.connectionClosed
            }
            finishTurn(turnToken: turnToken)
            diagnostics.record(
                category: .acp,
                event: "acp_client.prompt_finished",
                fields: [
                    "connection_id": connectionID.uuidString,
                    "stop_reason": stopReason.rawValue,
                    "duration_ms": String(Self.elapsedMilliseconds(since: promptStartedAt)),
                ])
            return AgentRunResult(stopReason: stopReason)
        } catch {
            let clientError = userSafeError(error)
            await eventDelivery.finish(.drain)
            await close()
            finishTurn(turnToken: turnToken)
            diagnostics.record(
                category: .acp,
                event: "acp_client.prompt_failed",
                level: error is CancellationError ? .info : .error,
                fields: [
                    "connection_id": connectionID.uuidString,
                    "duration_ms": String(Self.elapsedMilliseconds(since: promptStartedAt)),
                    "error_type": String(describing: type(of: error)),
                ])
            throw clientError
        }
    }

    public func resolvePermission(
        turnToken: AgentTurnToken,
        requestID: ACPRequestID,
        optionID: String?
    ) async {
        let key = PendingPermissionKey(turnToken: turnToken, requestID: requestID)
        guard activeTurnToken == turnToken, !promptResponseWasReceived else {
            pendingPermissions.removeValue(forKey: key)
            diagnostics.record(
                category: .acp,
                event: "acp_client.permission_resolution_ignored",
                fields: [
                    "connection_id": connectionID.uuidString,
                    "reason": "inactive_turn",
                ])
            return
        }
        guard let permission = pendingPermissions.removeValue(forKey: key) else {
            diagnostics.record(
                category: .acp,
                event: "acp_client.permission_resolution_ignored",
                fields: [
                    "connection_id": connectionID.uuidString,
                    "reason": "request_not_pending",
                ])
            return
        }

        let result: ACPJSONValue
        if let optionID, permission.options.contains(where: { $0.id == optionID }) {
            result = permissionSelection(optionID: optionID)
        } else {
            result = permissionCancellation()
        }
        diagnostics.record(
            category: .acp,
            event: "acp_client.permission_resolved",
            fields: [
                "connection_id": connectionID.uuidString,
                "selection_valid": String(
                    optionID.map {
                        selectedOptionID in
                        permission.options.contains {
                            $0.id == selectedOptionID
                        }
                    } ?? false),
            ])
        await sendResponse(id: requestID, result: result)
    }

    public func cancel() async {
        guard activeTurnToken != nil,
            !promptResponseWasReceived,
            !isPromptCancelling
        else {
            diagnostics.record(
                category: .acp,
                event: "acp_client.cancel_ignored",
                fields: ["connection_id": connectionID.uuidString])
            return
        }

        isPromptCancelling = true
        diagnostics.record(
            category: .acp,
            event: "acp_client.cancel_started",
            fields: [
                "connection_id": connectionID.uuidString,
                "request_frame_published": String(promptFrameWasPublished),
                "pending_permission_count": String(pendingPermissions.count),
            ])
        await cancelPendingPermissions()
        await sendCancelIfPromptWasPublished()
    }

    public func close() async {
        guard !isClosing else {
            diagnostics.record(
                category: .acp,
                event: "acp_client.close_joined",
                fields: ["connection_id": connectionID.uuidString])
            await closeCompletion.wait()
            return
        }
        isClosing = true
        diagnostics.record(
            category: .acp,
            event: "acp_client.close_started",
            fields: [
                "connection_id": connectionID.uuidString,
                "pending_request_count": String(pendingRequests.count),
                "pending_permission_count": String(pendingPermissions.count),
            ])

        let eventDelivery = activeEventDelivery
        activeEventDelivery = nil
        activeTurnToken = nil
        activePromptRequestID = nil
        promptFrameWasPublished = false
        promptResponseWasReceived = false
        promptHadActivity = false
        isPromptCancelling = false
        cancelFrameWasSent = false

        await eventDelivery?.finish(.discard)
        await cancelPendingPermissions()
        if terminalError == nil {
            finalize(with: .connectionClosed)
        }

        let task = receiveTask
        await terminateTransport()
        task?.cancel()
        _ = await task?.result
        receiveTask = nil
        closeCompletion.resolve()
        diagnostics.record(
            category: .acp,
            event: "acp_client.close_finished",
            fields: ["connection_id": connectionID.uuidString])
    }

    func waitForInputCompletion() async {
        _ = await receiveTask?.result
    }

    func eventDeliverySnapshotForTesting() -> AgentRunEventDeliverySnapshot? {
        activeEventDelivery?.snapshotForTesting
    }

    private func start() async throws {
        let startedAtUptime = DispatchTime.now().uptimeNanoseconds
        diagnostics.record(
            category: .acp,
            event: "acp_client.connection_started",
            fields: [
                "connection_id": connectionID.uuidString,
                "provider": configuration.preset.rawValue,
            ])
        let output = await transport.output()
        receiveTask = Task {
            await self.receive(output)
        }

        do {
            let initializeResult = try await sendRequest(
                method: "initialize",
                params: .object([
                    "protocolVersion": .integer(1),
                    "clientCapabilities": .object([:]),
                    "clientInfo": .object([
                        "name": .string(Self.clientName),
                        "title": .string(Self.clientTitle),
                        "version": .string(Self.clientVersion),
                    ]),
                ]))
            try applyInitializeResult(initializeResult)

            let newSessionResult: ACPJSONValue
            do {
                newSessionResult = try await sendRequest(
                    method: "session/new",
                    params: .object([
                        "cwd": .string(configuration.workingDirectory),
                        "mcpServers": .array([]),
                    ]))
            } catch let error as ACPClientError {
                if case .remoteError(let code, _) = error, code == -32_000 {
                    let methods = authenticationMethodNames
                    await close()
                    throw ACPClientError.authenticationRequired(methods: methods)
                }
                throw error
            }

            let newSessionObject = try requiredObject(
                newSessionResult,
                named: "session/new result")
            let decodedSessionID = try requiredString(
                newSessionObject["sessionId"],
                named: "sessionId")
            guard !decodedSessionID.isEmpty else {
                throw ACPClientError.malformedResponse("sessionId is empty.")
            }
            guard decodedSessionID.utf8.count <= ACPEventDecoder.maximumOpaqueIdentifierBytes else {
                throw ACPClientError.malformedResponse(
                    "sessionId exceeds the opaque identifier limit.")
            }
            sessionID = decodedSessionID
            diagnostics.record(
                category: .acp,
                event: "acp_client.connection_ready",
                fields: [
                    "connection_id": connectionID.uuidString,
                    "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
                    "authentication_method_count": String(authenticationMethodNames.count),
                ])
        } catch {
            let clientError = userSafeError(error)
            await close()
            diagnostics.record(
                category: .acp,
                event: "acp_client.connection_failed",
                level: .error,
                fields: [
                    "connection_id": connectionID.uuidString,
                    "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
                    "error_type": String(describing: type(of: error)),
                ])
            throw clientError
        }
    }

    private func applyInitializeResult(_ value: ACPJSONValue) throws {
        let result = try requiredObject(value, named: "initialize result")
        let protocolVersion = try requiredInteger(
            result["protocolVersion"],
            named: "protocolVersion")
        guard protocolVersion == 1 else {
            throw ACPClientError.incompatibleProtocol(selected: protocolVersion)
        }

        if let agentInfo = result["agentInfo"], agentInfo != .null {
            let information = try requiredObject(agentInfo, named: "agentInfo")
            let title = try optionalString(information["title"], named: "agentInfo.title")
            let name = try optionalString(information["name"], named: "agentInfo.name")
            agentName = title ?? name ?? configuration.displayName
        } else {
            agentName = configuration.displayName
        }

        guard let methodsValue = result["authMethods"] else {
            authenticationMethodNames = []
            return
        }
        let methods = try requiredArray(methodsValue, named: "authMethods")
        authenticationMethodNames =
            try methods
            .prefix(Self.maximumAdvertisedAuthenticationMethods)
            .map { methodValue in
                let method = try requiredObject(methodValue, named: "authMethods entry")
                return boundedText(
                    try requiredString(method["name"], named: "authMethods name"),
                    maximumBytes: Self.maximumDiagnosticBytes)
            }
    }

    private func sendRequest(
        method: String,
        params: ACPJSONValue?
    ) async throws -> ACPJSONValue {
        try ensureOpen()
        let id = try reserveRequestID()
        pendingRequestMethods[id] = method
        pendingRequestStartedAt[id] = DispatchTime.now().uptimeNanoseconds
        diagnostics.record(
            category: .acp,
            event: "acp_client.request_started",
            fields: [
                "connection_id": connectionID.uuidString,
                "request_id": requestIDDescription(id),
                "method": method,
            ])

        do {
            try await write(.request(id: id, method: method, params: params))
        } catch {
            pendingRequests.removeValue(forKey: id)
            pendingRequestMethods.removeValue(forKey: id)
            pendingRequestStartedAt.removeValue(forKey: id)
            let failure = ACPClientError.connectionClosed
            finalize(with: failure)
            await terminateTransport()
            throw failure
        }

        return try await waitForResponse(id: id)
    }

    private func sendPromptRequest(params: ACPJSONValue?) async throws -> ACPJSONValue {
        try ensureOpen()
        let id = try reserveRequestID()
        activePromptRequestID = id
        pendingRequestMethods[id] = "session/prompt"
        pendingRequestStartedAt[id] = DispatchTime.now().uptimeNanoseconds
        diagnostics.record(
            category: .acp,
            event: "acp_client.request_started",
            fields: [
                "connection_id": connectionID.uuidString,
                "request_id": requestIDDescription(id),
                "method": "session/prompt",
            ])

        do {
            try await write(.request(id: id, method: "session/prompt", params: params))
        } catch {
            pendingRequests.removeValue(forKey: id)
            pendingRequestMethods.removeValue(forKey: id)
            pendingRequestStartedAt.removeValue(forKey: id)
            let failure = ACPClientError.connectionClosed
            finalize(with: failure)
            await terminateTransport()
            throw failure
        }

        promptFrameWasPublished = true
        await sendCancelIfPromptWasPublished()
        return try await waitForResponse(id: id)
    }

    private func reserveRequestID() throws -> ACPRequestID {
        guard nextRequestID < Int64.max else {
            throw ACPClientError.connectionClosed
        }

        let id = ACPRequestID.integer(nextRequestID)
        nextRequestID += 1
        pendingRequests[id] = PendingClientRequest()
        return id
    }

    private func waitForResponse(id: ACPRequestID) async throws -> ACPJSONValue {
        try await withCheckedThrowingContinuation { continuation in
            guard var pending = pendingRequests[id] else {
                continuation.resume(throwing: terminalError ?? .connectionClosed)
                return
            }

            if let result = pending.bufferedResult {
                pendingRequests.removeValue(forKey: id)
                resume(continuation, with: result)
            } else {
                pending.continuation = continuation
                pendingRequests[id] = pending
            }
        }
    }

    private func receive(_ output: AsyncThrowingStream<Data, any Error>) async {
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

    private func handle(_ message: ACPMessage) async throws {
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

    private func sessionUpdateBelongsToActiveSession(_ params: ACPJSONValue?) throws -> Bool {
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

    private func completePendingRequest(
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

    private func handleRequest(
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

    private func handlePermissionRequest(
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

    private func systemInstruction() -> String {
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

    private func decodePermissionRequest(
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

    private func cancelPendingPermissions() async {
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

    private func sendCancelIfPromptWasPublished() async {
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

    private func sendResponse(id: ACPRequestID, result: ACPJSONValue) async {
        do {
            try await write(
                .response(id: id, result: result),
                allowWhileClosing: true)
        } catch {
            finalize(with: .connectionClosed)
            await terminateTransport()
        }
    }

    private func sendErrorResponse(id: ACPRequestID, code: Int64, message: String) async {
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

    private func sendNotification(method: String, params: ACPJSONValue?) async {
        do {
            try await write(.notification(method: method, params: params))
        } catch {
            finalize(with: .connectionClosed)
            await terminateTransport()
        }
    }

    private func write(
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

    private func acquireWritePermit() async {
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

    private func releaseWritePermit() {
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

    private func deliver(_ event: AgentRunEvent) async throws {
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

    private func finishTurn(turnToken: AgentTurnToken) {
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

    private func ensureOpen() throws {
        if let terminalError {
            throw terminalError
        }
        if isClosing {
            throw ACPClientError.connectionClosed
        }
    }

    private func finalize(with error: ACPClientError) {
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

    private func terminateTransport() async {
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

    private func userSafeError(_ error: any Error) -> ACPClientError {
        if let clientError = error as? ACPClientError {
            return clientError
        }
        return terminalError ?? .connectionClosed
    }

    nonisolated private static func elapsedMilliseconds(since start: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= start else { return 0 }
        return (now - start) / 1_000_000
    }
}

extension ACPMessage {
    fileprivate var clientDiagnosticKind: String {
        switch self {
        case .request: "request"
        case .notification: "notification"
        case .response: "response"
        case .errorResponse: "error_response"
        }
    }

    fileprivate var clientDiagnosticMethod: String? {
        switch self {
        case .request(_, let method, _), .notification(let method, _): method
        case .response, .errorResponse: nil
        }
    }
}

extension AgentRunEvent {
    fileprivate var clientDiagnosticName: String {
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

private final class ACPClientCloseCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isResolved = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func resolve() {
        var continuations: [CheckedContinuation<Void, Never>] = []
        lock.withLock {
            guard !isResolved else {
                return
            }
            isResolved = true
            continuations = waiters
            waiters.removeAll()
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            var shouldResume = false
            lock.withLock {
                if isResolved {
                    shouldResume = true
                } else {
                    waiters.append(continuation)
                }
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private struct PendingClientRequest {
    enum Result {
        case success(ACPJSONValue)
        case failure(ACPClientError)
    }

    var continuation: CheckedContinuation<ACPJSONValue, any Error>?
    var bufferedResult: Result?
}

extension PendingClientRequest.Result {
    fileprivate var isFailure: Bool {
        if case .failure = self {
            return true
        }
        return false
    }
}

private struct PendingPermission {
    let options: [AgentPermissionOption]
}

private struct PendingPermissionKey: Hashable {
    let turnToken: AgentTurnToken
    let requestID: ACPRequestID
}

private struct DecodedPermissionRequest {
    let sessionID: String
    let toolCall: AgentToolCallUpdate
    let options: [AgentPermissionOption]
}

private func resume(
    _ continuation: CheckedContinuation<ACPJSONValue, any Error>,
    with result: PendingClientRequest.Result
) {
    switch result {
    case .success(let value):
        continuation.resume(returning: value)
    case .failure(let error):
        continuation.resume(throwing: error)
    }
}

private func permissionSelection(optionID: String) -> ACPJSONValue {
    .object([
        "outcome": .object([
            "outcome": .string("selected"),
            "optionId": .string(optionID),
        ])
    ])
}

private func permissionCancellation() -> ACPJSONValue {
    .object([
        "outcome": .object(["outcome": .string("cancelled")])
    ])
}

private func requiredObject(
    _ value: ACPJSONValue?,
    named name: String
) throws -> [String: ACPJSONValue] {
    guard case .object(let object) = value else {
        throw ACPClientError.malformedResponse("Invalid or missing \(name).")
    }
    return object
}

private func requiredArray(
    _ value: ACPJSONValue?,
    named name: String
) throws -> [ACPJSONValue] {
    guard case .array(let array) = value else {
        throw ACPClientError.malformedResponse("Invalid or missing \(name).")
    }
    return array
}

private func requiredString(_ value: ACPJSONValue?, named name: String) throws -> String {
    guard case .string(let string) = value else {
        throw ACPClientError.malformedResponse("Invalid or missing \(name).")
    }
    return string
}

private func requiredOpaqueString(_ value: ACPJSONValue?, named name: String) throws -> String {
    let identifier = try requiredString(value, named: name)
    guard identifier.utf8.count <= AgentRunEventDelivery.maximumOpaqueIdentifierBytes else {
        throw PermissionRequestError.oversized
    }
    return identifier
}

private func optionalString(_ value: ACPJSONValue?, named name: String) throws -> String? {
    guard let value, value != .null else {
        return nil
    }
    return try requiredString(value, named: name)
}

private func requiredInteger(_ value: ACPJSONValue?, named name: String) throws -> Int64 {
    switch value {
    case .integer(let integer):
        integer
    case .unsignedInteger(let integer) where integer <= Int64.max:
        Int64(integer)
    default:
        throw ACPClientError.malformedResponse("Invalid or missing \(name).")
    }
}

private func requiredRawValue<Value>(
    _ value: ACPJSONValue?,
    named name: String
) throws -> Value
where Value: RawRepresentable, Value.RawValue == String {
    let encoded = try requiredString(value, named: name)
    guard let decoded = Value(rawValue: encoded) else {
        throw ACPClientError.malformedResponse("Invalid \(name).")
    }
    return decoded
}

private func optionalRawValue<Value>(
    _ value: ACPJSONValue?,
    named name: String
) throws -> Value?
where Value: RawRepresentable, Value.RawValue == String {
    guard let value, value != .null else {
        return nil
    }
    return try requiredRawValue(value, named: name)
}

private func boundedText(_ value: String, maximumBytes: Int) -> String {
    let flattened =
        value
        .components(separatedBy: .newlines)
        .joined(separator: " ")
    guard flattened.utf8.count > maximumBytes else {
        return flattened
    }

    var result = ""
    var bytes = 0
    for character in flattened {
        let characterBytes = String(character).utf8.count
        guard bytes + characterBytes <= maximumBytes else {
            break
        }
        result.append(character)
        bytes += characterBytes
    }
    return result
}

private func requestIDDescription(_ id: ACPRequestID) -> String {
    switch id {
    case .null:
        "null"
    case .integer(let value):
        String(value)
    case .string:
        "string ID"
    }
}

private enum PermissionRequestError: Error {
    case oversized
}

private func saturatingByteCount(_ lhs: Int, _ rhs: Int) -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : result
}

private func permissionRetainedByteCount(_ request: AgentPermissionRequest) -> Int {
    var count = request.toolCall.id.utf8.count + (request.toolCall.title?.utf8.count ?? 0)
    if case .string(let identifier) = request.requestID {
        count = saturatingByteCount(count, identifier.utf8.count)
    }
    for option in request.options {
        count = saturatingByteCount(count, option.id.utf8.count)
        count = saturatingByteCount(count, option.label.utf8.count)
    }
    return count
}

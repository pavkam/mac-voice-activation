// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// Failures produced by one initialized ACP client connection.
public enum ACPClientError: Error, Equatable, LocalizedError, Sendable {
    /// The underlying transport ended or was explicitly closed.
    case connectionClosed
    /// The harness selected an unsupported ACP protocol version.
    case incompatibleProtocol(selected: Int64)
    /// The harness requires authentication before a session can be created.
    case authenticationRequired(methods: [String])
    /// The prompt exceeds the bounded UTF-8 payload size.
    case promptTooLarge(maximumBytes: Int)
    /// The connection already has one active prompt.
    case promptAlreadyActive
    /// Required control events exceeded the bounded delivery queue.
    case eventDeliveryOverflow
    /// The harness sent a structurally invalid success response.
    case malformedResponse(String)
    /// The remote session disappeared and may be recreated by the runner.
    case sessionUnavailable(code: Int64, message: String)
    /// A non-recoverable remote JSON-RPC request failed.
    case remoteError(code: Int64, message: String)

    /// A user-presentable explanation of the ACP failure.
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

/// Owns protocol state, ordered writes, and one active prompt over an ACP transport.
public actor ACPClientConnection {
    /// The maximum accepted UTF-8 prompt payload.
    public static let maximumPromptBytes = 8_192
    /// The maximum retained UTF-8 size for one remote diagnostic summary.
    public static let maximumDiagnosticBytes = 256
    /// The maximum number of simultaneous unanswered permission requests.
    public static let maximumPendingPermissions = 32

    static let maximumAdvertisedAuthenticationMethods = 8
    static let clientName = "voice-activation"
    static let clientTitle = "Voice Activation"
    static let clientVersion = "0.1.0"
    static let markdownPresentationPreamble = """
        System instruction from Voice Activation:
        \(ACPAgentInstruction.responseStyle)
        """
    static let markdownPresentationInstruction = """
        \(markdownPresentationPreamble)
        The following content block is the user's request.
        """

    let transport: any ACPTransport
    let configuration: AgentHarnessConfiguration
    let diagnostics: any VoiceActivationDiagnosticRecording
    let connectionID = UUID()
    let eventDecoder = ACPEventDecoder()
    var receiveTask: Task<Void, Never>?
    var nextRequestID: Int64 = 1
    var pendingRequests: [ACPRequestID: PendingClientRequest] = [:]
    var pendingRequestMethods: [ACPRequestID: String] = [:]
    var pendingRequestStartedAt: [ACPRequestID: UInt64] = [:]
    var pendingPermissions: [PendingPermissionKey: PendingPermission] = [:]
    var authenticationMethodNames: [String] = []
    var sessionID: String?
    var agentName: String?
    var activeEventDelivery: AgentRunEventDelivery?
    var activeTurnToken: AgentTurnToken?
    var activePromptRequestID: ACPRequestID?
    var promptFrameWasPublished = false
    var promptResponseWasReceived = false
    var promptHadActivity = false
    var isPromptCancelling = false
    var cancelFrameWasSent = false
    var terminalError: ACPClientError?
    var transportWasTerminated = false
    var isClosing = false
    let closeCompletion = ACPClientCloseCompletion()
    var writeIsActive = false
    var writeWaiters: [CheckedContinuation<Void, Never>] = []
    var writeWaiterHead = 0

    init(
        transport: any ACPTransport,
        configuration: AgentHarnessConfiguration,
        diagnostics: any VoiceActivationDiagnosticRecording
    ) {
        self.transport = transport
        self.configuration = configuration
        self.diagnostics = diagnostics
    }

    /// Initializes the ACP protocol and creates one remote session.
    ///
    /// - Parameters:
    ///   - transport: The already-started framed transport.
    ///   - configuration: The agent identity, permissions, and working context.
    ///   - diagnostics: The privacy-safe lifecycle recorder.
    /// - Returns: An initialized connection ready for one prompt at a time.
    /// - Throws: ``ACPClientError`` or a transport error when initialization fails.
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

    /// Sends one prompt and streams ordered events until the harness returns a stop reason.
    ///
    /// - Parameters:
    ///   - prompt: The complete user prompt, excluding the protocol system instruction.
    ///   - onEvent: Receives ordered streaming output and control events.
    /// - Returns: The terminal result reported by the harness.
    /// - Throws: ``ACPClientError`` when the prompt or connection cannot complete safely.
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

    /// Answers a pending permission request if it still belongs to the active turn.
    ///
    /// - Parameters:
    ///   - turnToken: The local identity of the requesting turn.
    ///   - requestID: The JSON-RPC request identifier.
    ///   - optionID: A valid offered option, or `nil` to cancel the request.
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

    /// Cancels the active prompt and rejects any still-pending permissions.
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

    /// Idempotently closes the connection and joins its receive loop.
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

}

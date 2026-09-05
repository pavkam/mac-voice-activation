// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

extension ACPClientConnection {
    func start() async throws {
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

    func applyInitializeResult(_ value: ACPJSONValue) throws {
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

    func sendRequest(
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

    func sendPromptRequest(params: ACPJSONValue?) async throws -> ACPJSONValue {
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

    func reserveRequestID() throws -> ACPRequestID {
        guard nextRequestID < Int64.max else {
            throw ACPClientError.connectionClosed
        }

        let id = ACPRequestID.integer(nextRequestID)
        nextRequestID += 1
        pendingRequests[id] = PendingClientRequest()
        return id
    }

    func waitForResponse(id: ACPRequestID) async throws -> ACPJSONValue {
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

}

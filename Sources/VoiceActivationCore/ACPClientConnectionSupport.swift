// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

extension ACPMessage {
    var clientDiagnosticKind: String {
        switch self {
        case .request: "request"
        case .notification: "notification"
        case .response: "response"
        case .errorResponse: "error_response"
        }
    }

    var clientDiagnosticMethod: String? {
        switch self {
        case .request(_, let method, _), .notification(let method, _): method
        case .response, .errorResponse: nil
        }
    }
}

extension AgentRunEvent {
    var clientDiagnosticName: String {
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

/// Lets concurrent close callers join one transport teardown without duplicate work.
final class ACPClientCloseCompletion: @unchecked Sendable {
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

/// Retains one JSON-RPC continuation until its matching response or terminal failure.
struct PendingClientRequest {
    enum Result {
        case success(ACPJSONValue)
        case failure(ACPClientError)
    }

    var continuation: CheckedContinuation<ACPJSONValue, any Error>?
    var bufferedResult: Result?
}

extension PendingClientRequest.Result {
    var isFailure: Bool {
        if case .failure = self {
            return true
        }
        return false
    }
}

/// Retains the validated options offered by one blocking permission request.
struct PendingPermission {
    let options: [AgentPermissionOption]
}

/// Prevents identical remote request identifiers from crossing local turn boundaries.
struct PendingPermissionKey: Hashable {
    let turnToken: AgentTurnToken
    let requestID: ACPRequestID
}

/// The validated remote permission payload before policy selection and publication.
struct DecodedPermissionRequest {
    let sessionID: String
    let toolCall: AgentToolCallUpdate
    let options: [AgentPermissionOption]
}

func resume(
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

func permissionSelection(optionID: String) -> ACPJSONValue {
    .object([
        "outcome": .object([
            "outcome": .string("selected"),
            "optionId": .string(optionID),
        ])
    ])
}

func permissionCancellation() -> ACPJSONValue {
    .object([
        "outcome": .object(["outcome": .string("cancelled")])
    ])
}

func requiredObject(
    _ value: ACPJSONValue?,
    named name: String
) throws -> [String: ACPJSONValue] {
    guard case .object(let object) = value else {
        throw ACPClientError.malformedResponse("Invalid or missing \(name).")
    }
    return object
}

func requiredArray(
    _ value: ACPJSONValue?,
    named name: String
) throws -> [ACPJSONValue] {
    guard case .array(let array) = value else {
        throw ACPClientError.malformedResponse("Invalid or missing \(name).")
    }
    return array
}

func requiredString(_ value: ACPJSONValue?, named name: String) throws -> String {
    guard case .string(let string) = value else {
        throw ACPClientError.malformedResponse("Invalid or missing \(name).")
    }
    return string
}

func requiredOpaqueString(_ value: ACPJSONValue?, named name: String) throws -> String {
    let identifier = try requiredString(value, named: name)
    guard identifier.utf8.count <= AgentRunEventDelivery.maximumOpaqueIdentifierBytes else {
        throw PermissionRequestError.oversized
    }
    return identifier
}

func optionalString(_ value: ACPJSONValue?, named name: String) throws -> String? {
    guard let value, value != .null else {
        return nil
    }
    return try requiredString(value, named: name)
}

func requiredInteger(_ value: ACPJSONValue?, named name: String) throws -> Int64 {
    switch value {
    case .integer(let integer):
        integer
    case .unsignedInteger(let integer) where integer <= Int64.max:
        Int64(integer)
    default:
        throw ACPClientError.malformedResponse("Invalid or missing \(name).")
    }
}

func requiredRawValue<Value>(
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

func optionalRawValue<Value>(
    _ value: ACPJSONValue?,
    named name: String
) throws -> Value?
where Value: RawRepresentable, Value.RawValue == String {
    guard let value, value != .null else {
        return nil
    }
    return try requiredRawValue(value, named: name)
}

func boundedText(_ value: String, maximumBytes: Int) -> String {
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

func requestIDDescription(_ id: ACPRequestID) -> String {
    switch id {
    case .null:
        "null"
    case .integer(let value):
        String(value)
    case .string:
        "string ID"
    }
}

/// Internal validation failures for malformed permission request envelopes.
enum PermissionRequestError: Error {
    case oversized
}

func saturatingByteCount(_ lhs: Int, _ rhs: Int) -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : result
}

func permissionRetainedByteCount(_ request: AgentPermissionRequest) -> Int {
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

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

extension AgentRunEvent {
    var runnerDiagnosticName: String {
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
    var isSessionUnavailable: Bool {
        if case .sessionUnavailable = self {
            return true
        }
        return false
    }
}

/// Owns one cached profile transport, connection, process observers, and bounded diagnostics.
final class ACPAgentConnectionRecord {
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

/// Tracks the identities and cancellation state needed to reject callbacks from retired turns.
struct ACPAgentActiveTurn {
    let token: UUID
    let profileID: UUID
    var recordID: UUID?
    var connection: ACPClientConnection?
    let completion: ACPAgentRunCompletionLatch
    let delivery: AgentRunEventDelivery
    var isCancelling: Bool
    var deliveryOverflowed: Bool
}

/// The minimal terminal value needed by the cancellation race.
enum ACPAgentRunCompletion: Sendable {
    case success(AgentRunResult)
    case failure
}

/// The winner of cooperative turn completion versus the cancellation deadline.
enum ACPAgentCancellationRace: Sendable {
    case completion(ACPAgentRunCompletion)
    case deadline
}

/// The winner of process stream draining versus its bounded grace period.
enum ACPAgentDrainRace: Sendable {
    case drained
    case deadline
}

/// The event observed during the short post-prompt process stability window.
enum ACPAgentPromptSettleRace: Sendable {
    case processExited
    case settled
    case cancelled
}

/// The first terminal outcome produced while starting one ACP connection.
enum ACPAgentConnectionStartupOutcome: Sendable {
    case connected(ACPClientConnection)
    case failed(any Error)
    case cancelled
    case timedOut
}

/// Indicates whether process exit or local waiter cancellation happened first.
enum ACPAgentProcessExitWaitResult: Sendable {
    case processExited
    case cancelled
}

/// Broadcasts one observed process exit to cancellation-aware asynchronous waiters.
actor ACPAgentProcessExitLatch {
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

/// Broadcasts one run completion without allowing cancellation to overwrite a result.
actor ACPAgentRunCompletionLatch {
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

func decodeAvailableUTF8(appending data: Data, remainder: inout Data) -> String {
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

func trailingIncompleteUTF8ByteCount(in data: Data) -> Int {
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

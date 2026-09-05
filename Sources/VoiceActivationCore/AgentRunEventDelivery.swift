// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

enum AgentRunEventDeliveryFinishMode: Sendable {
    case drain
    case discard
}

enum AgentRunEventDeliveryAdmission: Equatable, Sendable {
    case accepted
    case ignored
    case stopped
    case capacityExceeded
    case invalid
}

enum AgentRunEventDeliveryLifecycleState: Equatable, Sendable {
    case open
    case draining
    case discarded
}

struct AgentRunEventDeliverySnapshot: Equatable, Sendable {
    let state: AgentRunEventDeliveryLifecycleState
    let pendingOutputBytes: Int
    let pendingDiagnosticBytes: Int
    let pendingControlBytes: Int
    let pendingEntryCount: Int
    let discardedOutputBytes: UInt64
    let discardedOutputEntries: UInt64
    let discardedDiagnosticBytes: UInt64
}

final class AgentRunEventDelivery: @unchecked Sendable {
    static let maximumPendingOutputBytes = 512 * 1_024
    static let maximumPendingDiagnosticBytes = 16 * 1_024
    static let maximumPendingControlBytes = 512 * 1_024
    static let maximumPendingEntries = 256
    static let maximumOpaqueIdentifierBytes = 4 * 1_024
    static let maximumPermissionOptions = 64
    static let maximumPlanEntries = 64

    private let state: AgentRunEventDeliveryQueue
    private let completion: AgentRunEventDeliveryCompletion
    private var consumerTask: Task<Void, Never>!

    var snapshotForTesting: AgentRunEventDeliverySnapshot {
        state.snapshot
    }

    init(handler: @escaping @Sendable (AgentRunEvent) async -> Void) {
        let state = AgentRunEventDeliveryQueue()
        let completion = AgentRunEventDeliveryCompletion()
        self.state = state
        self.completion = completion
        consumerTask = Task.detached(priority: .userInitiated) {
            while let event = await state.next() {
                await handler(event)
            }
            completion.resolve()
        }
    }

    deinit {
        state.discard()
        consumerTask.cancel()
        completion.resolve()
    }

    @discardableResult
    func send(_ event: AgentRunEvent) -> AgentRunEventDeliveryAdmission {
        state.send(event)
    }

    func stopAdmission() {
        state.startDraining()
    }

    func finish(_ mode: AgentRunEventDeliveryFinishMode) async {
        switch mode {
        case .drain:
            state.startDraining()
            await completion.wait()
        case .discard:
            state.discard()
            consumerTask.cancel()
            completion.resolve()
        }
    }

    func waitForConsumerTerminationForTesting() async {
        _ = await consumerTask.result
    }
}

private final class AgentRunEventDeliveryCompletion: @unchecked Sendable {
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

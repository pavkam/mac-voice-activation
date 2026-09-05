// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore

actor RunnerEventRecorder {
    private var events: [AgentRunEvent] = []
    private var waiters: [CheckedContinuation<AgentRunEvent, Never>] = []

    func record(_ event: AgentRunEvent) {
        if waiters.isEmpty {
            events.append(event)
        } else {
            waiters.removeFirst().resume(returning: event)
        }
    }

    func nextEvent() async -> AgentRunEvent {
        if !events.isEmpty {
            return events.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func recordedEvents() -> [AgentRunEvent] {
        events
    }
}

final class RunnerDiagnosticRecorder: VoiceActivationDiagnosticRecording,
    @unchecked Sendable
{
    struct Entry: Sendable {
        let event: String
        let fields: [String: String]
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(
        category: VoiceActivationDiagnosticCategory,
        event: String,
        level: VoiceActivationDiagnosticLevel,
        fields: [String: String]
    ) {
        lock.withLock {
            entries.append(Entry(event: event, fields: fields))
        }
    }

    func flush() {}

    func snapshot() -> [Entry] {
        lock.withLock { entries }
    }
}

actor RunnerEventGate {
    private var didEnter = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        didEnter = true
        let observers = entryWaiters
        entryWaiters.removeAll()
        for observer in observers {
            observer.resume()
        }
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else {
            return
        }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

actor RunnerTransportFactory: ACPTransportCreating {
    private var transports: [FakeACPTransport]
    private var configurations: [AgentHarnessConfiguration] = []

    init(transports: [FakeACPTransport]) {
        self.transports = transports
    }

    func makeTransport(
        configuration: AgentHarnessConfiguration) async throws -> any ACPTransport
    {
        configurations.append(configuration)
        guard !transports.isEmpty else {
            throw FakeACPTransportError.outputFailed
        }
        return transports.removeFirst()
    }

    func createdConfigurations() -> [AgentHarnessConfiguration] {
        configurations
    }
}

actor SuspendedRunnerTransportFactory: ACPTransportCreating {
    private let transport: FakeACPTransport
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    init(transport: FakeACPTransport) {
        self.transport = transport
    }

    func makeTransport(
        configuration: AgentHarnessConfiguration) async throws -> any ACPTransport
    {
        let waiting = observers
        observers.removeAll()
        for observer in waiting {
            observer.resume()
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return transport
    }

    func waitUntilRequested() async {
        guard continuation == nil else {
            return
        }
        await withCheckedContinuation { continuation in
            observers.append(continuation)
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

actor ManualACPAgentRunnerClock: ACPAgentRunnerClock {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waiters: [UUID: Waiter] = [:]
    private var waitingObservers: [CheckedContinuation<Void, Never>] = []
    private var durations: [Duration] = []

    func sleep(for duration: Duration) async {
        let id = UUID()
        durations.append(duration)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = Waiter(continuation: continuation)
                    let observers = waitingObservers
                    waitingObservers.removeAll()
                    for observer in observers {
                        observer.resume()
                    }
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitUntilSleeping() async {
        guard waiters.isEmpty else {
            return
        }
        await withCheckedContinuation { continuation in
            waitingObservers.append(continuation)
        }
    }

    func advance() {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume()
        }
    }

    func observedDurations() -> [Duration] {
        durations
    }

    func isSleeping() -> Bool {
        !waiters.isEmpty
    }

    private func cancel(id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }
}

actor DelayedCancellationACPAgentRunnerClock: ACPAgentRunnerClock {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var waitingObservers: [CheckedContinuation<Void, Never>] = []

    func sleep(for duration: Duration) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
                let observers = waitingObservers
                waitingObservers.removeAll()
                for observer in observers {
                    observer.resume()
                }
            }
        } onCancel: {
            Task {
                try? await ContinuousClock().sleep(for: .milliseconds(100))
                await self.cancel(id: id)
            }
        }
    }

    func waitUntilSleeping() async {
        guard waiters.isEmpty else {
            return
        }
        await withCheckedContinuation { continuation in
            waitingObservers.append(continuation)
        }
    }

    private func cancel(id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

actor RunnerPromptSettleCancellationGate {
    private var didPause = false
    private var isOpen = false
    private var pauseObservers: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        didPause = true
        let observers = pauseObservers
        pauseObservers.removeAll()
        for observer in observers {
            observer.resume()
        }
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilPaused() async {
        guard !didPause else {
            return
        }
        await withCheckedContinuation { continuation in
            pauseObservers.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

actor RunnerCompletionObservation {
    private var didComplete = false

    func complete() {
        didComplete = true
    }

    func completed() -> Bool {
        didComplete
    }
}

@Suite(.serialized)
struct ACPAgentRunnerTests {
}

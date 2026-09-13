// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import YapOpsCore

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

    func record(_ streamEvent: AgentRunStreamEvent) {
        guard case .live(let event) = streamEvent else { return }
        record(event)
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

final class RunnerDiagnosticRecorder: YapOpsDiagnosticRecording,
    @unchecked Sendable
{
    struct Entry: Sendable {
        let event: String
        let fields: [String: String]
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(
        category: YapOpsDiagnosticCategory,
        event: String,
        level: YapOpsDiagnosticLevel,
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
    private var unobservedSleepEntries = 0
    private var durations: [Duration] = []

    func sleep(for duration: Duration) async {
        let id = UUID()
        durations.append(duration)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    // An already-cancelled sleep never parks, but it did enter.
                    // Callers of `waitUntilSleeping()` are observing the entry,
                    // not the park, so this path owes them the same report.
                    recordSleepEntry()
                    continuation.resume()
                    return
                }
                waiters[id] = Waiter(continuation: continuation)
                recordSleepEntry()
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitUntilSleeping() async {
        if unobservedSleepEntries > 0 {
            unobservedSleepEntries -= 1
            return
        }
        guard waiters.isEmpty else {
            return
        }
        await withCheckedContinuation { continuation in
            waitingObservers.append(continuation)
        }
    }

    /// Hands one sleep entry to whoever is already waiting, or retains it for
    /// the next observer so an entry can never be missed by arriving early.
    private func recordSleepEntry() {
        guard waitingObservers.isEmpty else {
            let observers = waitingObservers
            waitingObservers.removeAll()
            for observer in observers {
                observer.resume()
            }
            return
        }
        unobservedSleepEntries += 1
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

extension ACPAgentRunnerTests {
    /// `raceDrain` adds its clock task to a group whose parent may already be
    /// cancelled, so that task enters `sleep(for:)` with cancellation already
    /// observed and never parks. The clock still owes that entry to whoever is
    /// observing it; when it did not, `waitUntilSleeping()` waited for a park
    /// that was never going to happen and the whole suite stopped.
    @Test func manualClock_WhenSleepEntersAlreadyCancelled_StillReportsTheEnteredSleep()
        async throws
    {
        let clock = ManualACPAgentRunnerClock()
        let entry = RunnerPromptSettleCancellationGate()
        let sleeping = Task {
            await entry.pause()
            await clock.sleep(for: .seconds(1))
        }

        // Retire the sleeper while it is held short of the clock, so the call
        // below is guaranteed to enter `sleep(for:)` already cancelled.
        await entry.waitUntilPaused()
        sleeping.cancel()
        await entry.open()
        _ = await sleeping.value

        #expect(await clock.observedDurations() == [.seconds(1)])
        #expect(await clock.isSleeping() == false)

        // `waitUntilSleeping()` parks on a continuation that cancellation cannot
        // reach, so a regression hangs the run instead of failing it: neither
        // `.timeLimit` nor a task group can retire this wait. Bound the
        // observation so the contract break is reported rather than waited out.
        let completion = RunnerCompletionObservation()
        let observation = Task {
            await clock.waitUntilSleeping()
            await completion.complete()
        }
        defer { observation.cancel() }
        for _ in 0..<100 {
            if await completion.completed() { break }
            try await ContinuousClock().sleep(for: .milliseconds(50))
        }

        #expect(
            await completion.completed(),
            "The entered sleep was never reported to its observer.")
    }

    /// The same ownership rule one boundary further in. `processExitWasObserved
    /// DuringPromptSettlement` cancels its group as soon as settlement wins, so
    /// the exit waiter can reach `wait()` with cancellation already observed.
    /// That return is still a cancelled wait and still owes
    /// `beforeCancelledWaitReturns`, which is the only signal a caller has that
    /// the cancelled path ran.
    @Test func exitLatch_WhenWaitEntersAlreadyCancelled_StillRunsTheCancelledWaitHook()
        async throws
    {
        let hook = RunnerCompletionObservation()
        let latch = ACPAgentProcessExitLatch(
            beforeCancelledWaitReturns: { await hook.complete() })
        let entry = RunnerPromptSettleCancellationGate()
        let waiting = Task {
            await entry.pause()
            return await latch.wait()
        }

        // Retire the waiter before it reaches the latch, so `wait()` is entered
        // with cancellation already observed.
        await entry.waitUntilPaused()
        waiting.cancel()
        await entry.open()
        let result = await waiting.value

        guard case .cancelled = result else {
            Issue.record("Expected a cancelled wait, got \(result)")
            return
        }
        #expect(
            await hook.completed(),
            "A cancelled wait returned without running its cancelled-wait hook.")
    }
}

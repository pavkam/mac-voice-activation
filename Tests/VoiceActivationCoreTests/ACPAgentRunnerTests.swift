// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore

private actor RunnerEventRecorder {
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

private actor RunnerEventGate {
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

private actor RunnerTransportFactory: ACPTransportCreating {
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

private actor SuspendedRunnerTransportFactory: ACPTransportCreating {
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

private actor ManualACPAgentRunnerClock: ACPAgentRunnerClock {
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

private actor DelayedCancellationACPAgentRunnerClock: ACPAgentRunnerClock {
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

private actor RunnerPromptSettleCancellationGate {
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

private actor RunnerCompletionObservation {
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
    @Test func run_WhenProfileConfigurationIsUnchanged_ReusesConnectionAndSession() async throws {
        let transport = FakeACPTransport()
        let factory = RunnerTransportFactory(transports: [transport])
        let runner = ACPAgentRunner(transportFactory: factory)
        let profileID = UUID()
        let configuration = try makeConfiguration()

        let firstRun = run(runner, profileID: profileID, configuration: configuration)
        try await establishConnection(transport, workingDirectory: "/tmp/project")
        #expect(await transport.nextSentMessage() == promptRequest(id: 3, text: "First"))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        #expect(try await firstRun.value == AgentRunResult(stopReason: .endTurn))

        let secondRun = run(
            runner,
            profileID: profileID,
            configuration: configuration,
            prompt: "Second")
        #expect(await transport.nextSentMessage() == promptRequest(id: 4, text: "Second"))
        try await transport.feed(promptResponse(id: 4, stopReason: "end_turn"))
        #expect(try await secondRun.value == AgentRunResult(stopReason: .endTurn))
        #expect(await transport.allSentMessages().filter(isSessionCreation).count == 1)
        #expect(await factory.createdConfigurations() == [configuration])

        await runner.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func run_WhenCachedSessionNoLongerExists_ReconnectsAndRetriesOnce() async throws {
        let staleTransport = FakeACPTransport()
        let replacementTransport = FakeACPTransport()
        let factory = RunnerTransportFactory(
            transports: [staleTransport, replacementTransport])
        let runner = ACPAgentRunner(transportFactory: factory)
        let recorder = RunnerEventRecorder()
        let profileID = UUID()
        let configuration = try makeConfiguration()

        let warmup = run(runner, profileID: profileID, configuration: configuration)
        try await establishConnection(
            staleTransport,
            workingDirectory: "/tmp/project",
            sessionID: "stale-session")
        #expect(await staleTransport.nextSentMessage() == promptRequest(
            id: 3,
            text: "First",
            sessionID: "stale-session"))
        try await staleTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await warmup.value

        let recoveredRun = Task {
            try await runner.run(
                profileID: profileID,
                configuration: configuration,
                prompt: "Continue safely",
                onEvent: { event in await recorder.record(event) })
        }
        #expect(await staleTransport.nextSentMessage() == promptRequest(
            id: 4,
            text: "Continue safely",
            sessionID: "stale-session"))
        try await staleTransport.feed(.errorResponse(
            id: .integer(4),
            error: ACPJSONRPCError(
                code: -32_002,
                message: "Resource not found",
                data: .object([
                    "resourceType": .string("session"),
                    "resourceId": .string("stale-session"),
                ]))))

        try await establishConnection(
            replacementTransport,
            workingDirectory: "/tmp/project",
            sessionID: "replacement-session")
        #expect(await replacementTransport.nextSentMessage() == promptRequest(
            id: 3,
            text: "Continue safely",
            sessionID: "replacement-session"))
        try await replacementTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))

        #expect(try await recoveredRun.value == AgentRunResult(stopReason: .endTurn))
        #expect(await recorder.recordedEvents() == [
            .connected(agentName: "Test Agent", sessionID: "stale-session"),
            .metadata(
                kind: AgentRunMetadataKind.sessionRecovered,
                summary: ACPAgentRunner.sessionRecoveryNotice),
            .connected(agentName: "Test Agent", sessionID: "replacement-session"),
        ])
        #expect(await staleTransport.observedTerminationCount() == 1)
        #expect(await factory.createdConfigurations() == [configuration, configuration])

        await runner.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func run_WhenInitialConnectionStopsResponding_RestartsWithFreshConnection() async throws {
        let stalledTransport = FakeACPTransport(finishesReadStreamsOnTermination: false)
        let replacementTransport = FakeACPTransport()
        let factory = RunnerTransportFactory(
            transports: [stalledTransport, replacementTransport])
        let clock = ManualACPAgentRunnerClock()
        let drainClock = ManualACPAgentRunnerClock()
        let runner = ACPAgentRunner(
            transportFactory: factory,
            startupClock: clock,
            drainClock: drainClock,
            testingHooks: ACPAgentRunnerTestingHooks())
        let recorder = RunnerEventRecorder()
        let profileID = UUID()
        let configuration = try makeConfiguration()
        let activeRun = Task {
            try await runner.run(
                profileID: profileID,
                configuration: configuration,
                prompt: "Recover startup",
                onEvent: { event in await recorder.record(event) })
        }

        #expect(await stalledTransport.nextSentMessage() == .request(
            id: .integer(1),
            method: "initialize",
            params: .object([
                "protocolVersion": .integer(1),
                "clientCapabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("voice-activation"),
                    "title": .string("Voice Activation"),
                    "version": .string("0.1.0"),
                ]),
            ])))
        let deadlineStarted = await waitUntil { await clock.isSleeping() }
        #expect(deadlineStarted)
        guard deadlineStarted else {
            await stalledTransport.terminate()
            _ = try? await activeRun.value
            return
        }

        await clock.advance()
        let didRetry = await waitUntil {
            await factory.createdConfigurations().count == 2
        }
        #expect(didRetry)
        guard didRetry else {
            activeRun.cancel()
            await stalledTransport.closeReadStreams()
            await drainClock.advance()
            await replacementTransport.closeReadStreams()
            _ = try? await activeRun.value
            return
        }

        try await establishConnection(
            replacementTransport,
            workingDirectory: "/tmp/project",
            sessionID: "replacement-session")
        #expect(await replacementTransport.nextSentMessage() == promptRequest(
            id: 3,
            text: "Recover startup",
            sessionID: "replacement-session"))
        try await replacementTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))

        #expect(try await activeRun.value == AgentRunResult(stopReason: .endTurn))
        #expect(await stalledTransport.observedTerminationCount() == 1)
        #expect(await stalledTransport.observedReadStreamCloseCount() == 1)
        let events = await recorder.recordedEvents()
        #expect(events == [
            .metadata(
                kind: AgentRunMetadataKind.sessionRecovered,
                summary: ACPAgentRunner.startupRecoveryNotice),
            .connected(agentName: "Test Agent", sessionID: "replacement-session"),
        ])
        await runner.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancel_WhenStartupRetainsReadStreams_ClosesThemWithoutWaitingForDeadline() async throws {
        let transport = FakeACPTransport(finishesReadStreamsOnTermination: false)
        let factory = RunnerTransportFactory(transports: [transport])
        let startupClock = ManualACPAgentRunnerClock()
        let cancellationClock = ManualACPAgentRunnerClock()
        let runner = ACPAgentRunner(
            transportFactory: factory,
            clock: cancellationClock,
            startupClock: startupClock,
            testingHooks: ACPAgentRunnerTestingHooks())
        let activeRun = run(
            runner,
            profileID: UUID(),
            configuration: try makeConfiguration())

        let didStart = await waitUntil {
            let didCreateTransport = await factory.createdConfigurations().count == 1
            let isWaitingForStartup = await startupClock.isSleeping()
            return didCreateTransport && isWaitingForStartup
        }
        #expect(didStart)
        guard didStart else {
            activeRun.cancel()
            await transport.closeReadStreams()
            _ = try? await activeRun.value
            return
        }

        activeRun.cancel()
        let cancellation = Task { await runner.cancel() }
        let didCloseStreams = await waitUntil {
            await transport.observedReadStreamCloseCount() == 1
        }
        #expect(didCloseStreams)
        if !didCloseStreams {
            await transport.closeReadStreams()
        }

        await #expect(throws: CancellationError.self) {
            try await activeRun.value
        }
        await cancellation.value
        #expect(await transport.observedTerminationCount() == 1)
        #expect(await cancellationClock.observedDurations() == [.seconds(2)])
    }

    @Test(.timeLimit(.minutes(1)))
    func run_WhenReplacementConnectionAlsoStopsResponding_RetriesOnlyOnce() async throws {
        let firstTransport = FakeACPTransport()
        let secondTransport = FakeACPTransport()
        let factory = RunnerTransportFactory(
            transports: [firstTransport, secondTransport])
        let clock = ManualACPAgentRunnerClock()
        let runner = ACPAgentRunner(
            transportFactory: factory,
            startupClock: clock,
            testingHooks: ACPAgentRunnerTestingHooks())
        let configuration = try makeConfiguration()
        let activeRun = run(runner, profileID: UUID(), configuration: configuration)

        _ = await firstTransport.nextSentMessage()
        #expect(await waitUntil { await clock.isSleeping() })
        await clock.advance()

        _ = await secondTransport.nextSentMessage()
        #expect(await waitUntil { await clock.isSleeping() })
        await clock.advance()

        await #expect(throws: ACPAgentRunnerError.startupTimedOut) {
            try await activeRun.value
        }
        #expect(await factory.createdConfigurations() == [configuration, configuration])
        #expect(await firstTransport.observedTerminationCount() == 1)
        #expect(await secondTransport.observedTerminationCount() == 1)
        await runner.shutdown()
    }

    @Test func run_WhenMissingResourceIsNotTheSession_DoesNotReplayPrompt() async throws {
        let failedTransport = FakeACPTransport()
        let unusedTransport = FakeACPTransport()
        let factory = RunnerTransportFactory(transports: [failedTransport, unusedTransport])
        let runner = ACPAgentRunner(transportFactory: factory)
        let configuration = try makeConfiguration()
        let activeRun = run(runner, profileID: UUID(), configuration: configuration)
        try await establishConnection(failedTransport, workingDirectory: "/tmp/project")
        _ = await failedTransport.nextSentMessage()

        try await failedTransport.feed(.errorResponse(
            id: .integer(3),
            error: ACPJSONRPCError(
                code: -32_002,
                message: "Resource not found",
                data: .object([
                    "resource": .string("file"),
                    "path": .string("/tmp/project/missing.txt"),
                ]))))

        await #expect(throws: ACPClientError.remoteError(
            code: -32_002,
            message: "Resource not found"))
        {
            try await activeRun.value
        }
        #expect(await factory.createdConfigurations() == [configuration])
        #expect(await failedTransport.observedTerminationCount() == 1)
        #expect(await unusedTransport.observedTerminationCount() == 0)
        await runner.shutdown()
    }

    @Test func run_WhenSessionDisappearsAfterActivity_DoesNotReplayPrompt() async throws {
        let failedTransport = FakeACPTransport()
        let unusedTransport = FakeACPTransport()
        let factory = RunnerTransportFactory(transports: [failedTransport, unusedTransport])
        let runner = ACPAgentRunner(transportFactory: factory)
        let configuration = try makeConfiguration()
        let activeRun = run(runner, profileID: UUID(), configuration: configuration)
        try await establishConnection(failedTransport, workingDirectory: "/tmp/project")
        _ = await failedTransport.nextSentMessage()
        try await failedTransport.feed(agentMessageUpdate(text: "Work already began"))
        try await failedTransport.feed(.errorResponse(
            id: .integer(3),
            error: ACPJSONRPCError(code: -32_603, message: "Session not found")))

        await #expect(throws: ACPClientError.remoteError(
            code: -32_603,
            message: "Session not found"))
        {
            try await activeRun.value
        }
        #expect(await factory.createdConfigurations() == [configuration])
        #expect(await failedTransport.observedTerminationCount() == 1)
        #expect(await unusedTransport.observedTerminationCount() == 0)
        await runner.shutdown()
    }

    @Test func run_WhenReplacementSessionIsAlsoMissing_RetriesOnlyOnce() async throws {
        let firstTransport = FakeACPTransport()
        let secondTransport = FakeACPTransport()
        let unusedTransport = FakeACPTransport()
        let factory = RunnerTransportFactory(
            transports: [firstTransport, secondTransport, unusedTransport])
        let runner = ACPAgentRunner(transportFactory: factory)
        let configuration = try makeConfiguration()
        let activeRun = run(runner, profileID: UUID(), configuration: configuration)

        try await establishConnection(
            firstTransport,
            workingDirectory: "/tmp/project",
            sessionID: "first-session")
        _ = await firstTransport.nextSentMessage()
        try await firstTransport.feed(.errorResponse(
            id: .integer(3),
            error: ACPJSONRPCError(code: -32_603, message: "Unknown session")))

        try await establishConnection(
            secondTransport,
            workingDirectory: "/tmp/project",
            sessionID: "second-session")
        _ = await secondTransport.nextSentMessage()
        try await secondTransport.feed(.errorResponse(
            id: .integer(3),
            error: ACPJSONRPCError(code: -32_603, message: "Unknown session")))

        await #expect(throws: ACPClientError.sessionUnavailable(
            code: -32_603,
            message: "Unknown session"))
        {
            try await activeRun.value
        }
        #expect(await factory.createdConfigurations() == [configuration, configuration])
        #expect(await firstTransport.observedTerminationCount() == 1)
        #expect(await secondTransport.observedTerminationCount() == 1)
        #expect(await unusedTransport.observedTerminationCount() == 0)
        await runner.shutdown()
    }

    @Test func run_WhenProfileConfigurationChanges_ReplacesConnection() async throws {
        let firstTransport = FakeACPTransport()
        let secondTransport = FakeACPTransport()
        let factory = RunnerTransportFactory(transports: [firstTransport, secondTransport])
        let runner = ACPAgentRunner(transportFactory: factory)
        let profileID = UUID()
        let firstConfiguration = try makeConfiguration()
        let secondConfiguration = try makeConfiguration(workingDirectory: "/tmp/other-project")

        let firstRun = run(runner, profileID: profileID, configuration: firstConfiguration)
        try await establishConnection(firstTransport, workingDirectory: "/tmp/project")
        _ = await firstTransport.nextSentMessage()
        try await firstTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await firstRun.value

        let secondRun = run(runner, profileID: profileID, configuration: secondConfiguration)
        try await establishConnection(secondTransport, workingDirectory: "/tmp/other-project")
        _ = await secondTransport.nextSentMessage()
        try await secondTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await secondRun.value

        #expect(await firstTransport.observedTerminationCount() == 1)
        #expect(await secondTransport.observedTerminationCount() == 0)
        #expect(await factory.createdConfigurations() == [firstConfiguration, secondConfiguration])
        await runner.shutdown()
    }

    @Test func run_WhenAnotherTurnIsActive_RejectsConcurrentPrompt() async throws {
        let firstTransport = FakeACPTransport()
        let unusedTransport = FakeACPTransport()
        let factory = RunnerTransportFactory(transports: [firstTransport, unusedTransport])
        let runner = ACPAgentRunner(transportFactory: factory)
        let firstRun = run(runner, profileID: UUID(), configuration: try makeConfiguration())
        try await establishConnection(firstTransport, workingDirectory: "/tmp/project")
        _ = await firstTransport.nextSentMessage()

        await #expect(throws: ACPAgentRunnerError.turnAlreadyActive) {
            try await runner.run(
                profileID: UUID(),
                configuration: try makeConfiguration(workingDirectory: "/tmp/second"),
                prompt: "Overlapping",
                onEvent: { _ in })
        }
        #expect(await factory.createdConfigurations().count == 1)

        try await firstTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await firstRun.value
        await runner.shutdown()
    }

    @Test func cancel_WhenAgentAcknowledgesWithinGrace_DoesNotTerminateProcess() async throws {
        let transport = FakeACPTransport()
        let factory = RunnerTransportFactory(transports: [transport])
        let clock = ManualACPAgentRunnerClock()
        let runner = ACPAgentRunner(transportFactory: factory, clock: clock)
        let profileID = UUID()
        let configuration = try makeConfiguration()
        let activeRun = run(runner, profileID: profileID, configuration: configuration)
        try await establishConnection(transport, workingDirectory: "/tmp/project")
        _ = await transport.nextSentMessage()

        let cancellation = Task { await runner.cancel() }
        #expect(await transport.nextSentMessage() == .notification(
            method: "session/cancel",
            params: .object(["sessionId": .string("session-1")])))
        try await transport.feed(promptResponse(id: 3, stopReason: "cancelled"))

        #expect(try await activeRun.value == AgentRunResult(stopReason: .cancelled))
        await cancellation.value
        #expect(await transport.observedTerminationCount() == 0)
        #expect(await clock.observedDurations() == [.seconds(2)])

        let reusedRun = run(
            runner,
            profileID: profileID,
            configuration: configuration,
            prompt: "After cancellation")
        #expect(await transport.nextSentMessage() == promptRequest(
            id: 4,
            text: "After cancellation"))
        try await transport.feed(promptResponse(id: 4, stopReason: "end_turn"))
        _ = try await reusedRun.value
        await runner.shutdown()
    }

    @Test func cancel_WhenAgentHangs_TerminatesAfterTwoSecondGrace() async throws {
        let firstTransport = FakeACPTransport()
        let secondTransport = FakeACPTransport()
        let factory = RunnerTransportFactory(transports: [firstTransport, secondTransport])
        let clock = ManualACPAgentRunnerClock()
        let runner = ACPAgentRunner(transportFactory: factory, clock: clock)
        let profileID = UUID()
        let configuration = try makeConfiguration()
        let activeRun = run(runner, profileID: profileID, configuration: configuration)
        try await establishConnection(firstTransport, workingDirectory: "/tmp/project")
        _ = await firstTransport.nextSentMessage()

        let cancellation = Task { await runner.cancel() }
        #expect(await firstTransport.nextSentMessage() == .notification(
            method: "session/cancel",
            params: .object(["sessionId": .string("session-1")])))
        await clock.waitUntilSleeping()
        await clock.advance()
        await cancellation.value

        #expect(await firstTransport.observedTerminationCount() == 1)
        await #expect(throws: ACPClientError.connectionClosed) {
            try await activeRun.value
        }

        let replacement = run(runner, profileID: profileID, configuration: configuration)
        try await establishConnection(secondTransport, workingDirectory: "/tmp/project")
        _ = await secondTransport.nextSentMessage()
        try await secondTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await replacement.value
        await runner.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancel_WhenCancelWriteIsBlocked_DeadlineStillTerminatesTransport() async throws {
        let transport = FakeACPTransport()
        let factory = RunnerTransportFactory(transports: [transport])
        let clock = ManualACPAgentRunnerClock()
        let runner = ACPAgentRunner(transportFactory: factory, clock: clock)
        let profileID = UUID()
        let configuration = try makeConfiguration()

        let warmup = run(runner, profileID: profileID, configuration: configuration)
        try await establishConnection(transport, workingDirectory: "/tmp/project")
        _ = await transport.nextSentMessage()
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await warmup.value

        let blockedRun = run(
            runner,
            profileID: profileID,
            configuration: configuration,
            prompt: "Block cancellation")
        _ = await transport.nextSentMessage()
        await transport.suspendNextSend()
        let cancellation = Task { await runner.cancel() }
        await transport.waitUntilSendIsSuspended()
        await clock.waitUntilSleeping()

        await clock.advance()
        await cancellation.value

        #expect(await transport.observedTerminationCount() == 1)
        await #expect(throws: ACPClientError.connectionClosed) {
            try await blockedRun.value
        }
    }

    @Test func cancel_WhenPreviousTurnFinishes_DoesNotTerminateLaterProfile() async throws {
        let firstTransport = FakeACPTransport()
        let secondTransport = FakeACPTransport()
        let factory = RunnerTransportFactory(transports: [firstTransport, secondTransport])
        let clock = ManualACPAgentRunnerClock()
        let runner = ACPAgentRunner(transportFactory: factory, clock: clock)
        let firstRun = run(
            runner,
            profileID: UUID(),
            configuration: try makeConfiguration())
        try await establishConnection(firstTransport, workingDirectory: "/tmp/project")
        _ = await firstTransport.nextSentMessage()
        let cancellation = Task { await runner.cancel() }
        _ = await firstTransport.nextSentMessage()
        try await firstTransport.feed(promptResponse(id: 3, stopReason: "cancelled"))
        _ = try await firstRun.value

        let laterRun = run(
            runner,
            profileID: UUID(),
            configuration: try makeConfiguration(workingDirectory: "/tmp/later"))
        try await establishConnection(secondTransport, workingDirectory: "/tmp/later")
        _ = await secondTransport.nextSentMessage()
        await cancellation.value
        await clock.advance()

        #expect(await secondTransport.observedTerminationCount() == 0)
        try await secondTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await laterRun.value
        await runner.shutdown()
    }

    @Test func run_WhenConnectionFails_DiscardsItBeforeNextAttempt() async throws {
        let firstTransport = FakeACPTransport()
        let secondTransport = FakeACPTransport()
        let factory = RunnerTransportFactory(transports: [firstTransport, secondTransport])
        let runner = ACPAgentRunner(transportFactory: factory)
        let profileID = UUID()
        let configuration = try makeConfiguration()
        let failedRun = run(runner, profileID: profileID, configuration: configuration)
        try await establishConnection(firstTransport, workingDirectory: "/tmp/project")
        _ = await firstTransport.nextSentMessage()
        try await firstTransport.feed(.errorResponse(
            id: .integer(3),
            error: ACPJSONRPCError(code: -32_603, message: "Failed")))

        await #expect(throws: ACPClientError.remoteError(code: -32_603, message: "Failed")) {
            try await failedRun.value
        }
        #expect(await firstTransport.observedTerminationCount() == 1)

        let retry = run(runner, profileID: profileID, configuration: configuration)
        try await establishConnection(secondTransport, workingDirectory: "/tmp/project")
        _ = await secondTransport.nextSentMessage()
        try await secondTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await retry.value
        await runner.shutdown()
    }

    @Test func run_WhenSuccessArrivesWithStalledHandler_DrainsEventsBeforeReturning()
        async throws
    {
        let transport = FakeACPTransport()
        let runner = ACPAgentRunner(
            transportFactory: RunnerTransportFactory(transports: [transport]))
        let gate = RunnerEventGate()
        let completion = RunnerCompletionObservation()
        let activeRun = Task {
            let result = try await runner.run(
                profileID: UUID(),
                configuration: try makeConfiguration(),
                prompt: "Drain success",
                onEvent: { _ in await gate.wait() })
            await completion.complete()
            return result
        }
        try await establishConnection(transport, workingDirectory: "/tmp/project")
        _ = await transport.nextSentMessage()
        await gate.waitUntilEntered()

        try await transport.feed(agentMessageUpdate(text: "queued"))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        for _ in 0..<50 {
            await Task.yield()
        }
        #expect(await completion.completed() == false)

        await gate.open()
        #expect(try await activeRun.value == AgentRunResult(stopReason: .endTurn))
        #expect(await completion.completed())
        await runner.shutdown()
    }

    @Test func run_WhenFailureArrivesWithStalledHandler_DrainsEventsBeforeThrowing()
        async throws
    {
        let transport = FakeACPTransport()
        let runner = ACPAgentRunner(
            transportFactory: RunnerTransportFactory(transports: [transport]))
        let gate = RunnerEventGate()
        let completion = RunnerCompletionObservation()
        let activeRun = Task {
            do {
                _ = try await runner.run(
                    profileID: UUID(),
                    configuration: try makeConfiguration(),
                    prompt: "Drain failure",
                    onEvent: { _ in await gate.wait() })
            } catch {
                await completion.complete()
                throw error
            }
        }
        try await establishConnection(transport, workingDirectory: "/tmp/project")
        _ = await transport.nextSentMessage()
        await gate.waitUntilEntered()

        try await transport.feed(agentMessageUpdate(text: "queued"))
        try await transport.feed(.errorResponse(
            id: .integer(3),
            error: ACPJSONRPCError(code: -32_603, message: "Failed")))
        for _ in 0..<50 {
            await Task.yield()
        }
        #expect(await completion.completed() == false)

        await gate.open()
        await #expect(throws: ACPClientError.remoteError(code: -32_603, message: "Failed")) {
            try await activeRun.value
        }
        #expect(await completion.completed())
        await runner.shutdown()
    }

    @Test func run_WhenRunnerControlDeliveryOverflows_DrainsPrefixAndCannotRaceToSuccess()
        async throws
    {
        let transport = FakeACPTransport()
        let runner = ACPAgentRunner(
            transportFactory: RunnerTransportFactory(transports: [transport]))
        let recorder = RunnerEventRecorder()
        let gate = RunnerEventGate()
        let activeRun = Task {
            try await runner.run(
                profileID: UUID(),
                configuration: try makeConfiguration(),
                prompt: "Overflow runner",
                onEvent: { event in
                    await gate.wait()
                    await recorder.record(event)
                })
        }
        try await establishConnection(transport, workingDirectory: "/tmp/project")
        _ = await transport.nextSentMessage()
        await gate.waitUntilEntered()

        for index in 0..<AgentRunEventDelivery.maximumPendingEntries {
            try await transport.feed(modeUpdate(id: "mode-\(index)"))
        }
        while await runner.eventDeliverySnapshotForTesting()?.pendingEntryCount
            != AgentRunEventDelivery.maximumPendingEntries
        {
            await Task.yield()
        }
        try await transport.feed(modeUpdate(
            id: "mode-\(AgentRunEventDelivery.maximumPendingEntries)"))
        while await runner.eventDeliverySnapshotForTesting()?.state != .draining {
            await Task.yield()
        }
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        await gate.open()

        await #expect(throws: ACPAgentRunnerError.eventDeliveryOverflow) {
            try await activeRun.value
        }
        let expected = [
            AgentRunEvent.connected(agentName: "Test Agent", sessionID: "session-1"),
        ] + (0..<AgentRunEventDelivery.maximumPendingEntries).map { index in
            AgentRunEvent.metadata(
                kind: "current_mode_update",
                summary: "Current mode: mode-\(index)")
        }
        #expect(await recorder.recordedEvents() == expected)
        #expect(await transport.observedTerminationCount() == 1)
    }

    @Test func shutdown_WhenConnectionsAreCached_ClosesEveryProcess() async throws {
        let firstTransport = FakeACPTransport()
        let secondTransport = FakeACPTransport()
        let factory = RunnerTransportFactory(transports: [firstTransport, secondTransport])
        let runner = ACPAgentRunner(transportFactory: factory)

        let firstRun = run(runner, profileID: UUID(), configuration: try makeConfiguration())
        try await establishConnection(firstTransport, workingDirectory: "/tmp/project")
        _ = await firstTransport.nextSentMessage()
        try await firstTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await firstRun.value

        let secondRun = run(
            runner,
            profileID: UUID(),
            configuration: try makeConfiguration(workingDirectory: "/tmp/second"))
        try await establishConnection(secondTransport, workingDirectory: "/tmp/second")
        _ = await secondTransport.nextSentMessage()
        try await secondTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await secondRun.value

        await runner.shutdown()

        #expect(await firstTransport.observedTerminationCount() == 1)
        #expect(await secondTransport.observedTerminationCount() == 1)
        await #expect(throws: ACPAgentRunnerError.shutDown) {
            try await runner.run(
                profileID: UUID(),
                configuration: try makeConfiguration(),
                prompt: "After shutdown",
                onEvent: { _ in })
        }
    }

    @Test func shutdown_WhenNaturalCompletionIsDraining_InvalidatesBeforeDiscardCanResumeRun()
        async throws
    {
        let transport = FakeACPTransport()
        let runner = ACPAgentRunner(
            transportFactory: RunnerTransportFactory(transports: [transport]))
        let gate = RunnerEventGate()
        let activeRun = Task {
            try await runner.run(
                profileID: UUID(),
                configuration: try makeConfiguration(),
                prompt: "Shutdown while draining",
                onEvent: { _ in await gate.wait() })
        }
        try await establishConnection(transport, workingDirectory: "/tmp/project")
        _ = await transport.nextSentMessage()
        await gate.waitUntilEntered()
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        while await runner.eventDeliverySnapshotForTesting()?.state != .draining {
            await Task.yield()
        }

        await runner.shutdown()

        await #expect(throws: ACPAgentRunnerError.cancelled) {
            try await activeRun.value
        }
        await gate.open()
    }

    @Test func shutdown_WhenSuccessIsReadyButNotPublished_InvalidatesTheRun() async throws {
        let transport = FakeACPTransport()
        let completionGate = RunnerEventGate()
        let runner = ACPAgentRunner(
            transportFactory: RunnerTransportFactory(transports: [transport]),
            testingHooks: ACPAgentRunnerTestingHooks(
                beforeSuccessIsPublished: { await completionGate.wait() }))
        let activeRun = Task {
            try await runner.run(
                profileID: UUID(),
                configuration: try makeConfiguration(),
                prompt: "Shutdown before success",
                onEvent: { _ in })
        }
        try await establishConnection(transport, workingDirectory: "/tmp/project")
        _ = await transport.nextSentMessage()
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        await completionGate.waitUntilEntered()

        await runner.shutdown()
        await completionGate.open()

        await #expect(throws: ACPAgentRunnerError.cancelled) {
            try await activeRun.value
        }
    }

    @Test func resolvePermission_WhenTurnTokenMatches_ForwardsExactDecision() async throws {
        let transport = FakeACPTransport()
        let runner = ACPAgentRunner(
            transportFactory: RunnerTransportFactory(transports: [transport]))
        let recorder = RunnerEventRecorder()
        let activeRun = Task {
            try await runner.run(
                profileID: UUID(),
                configuration: try makeConfiguration(),
                prompt: "Edit",
                onEvent: { event in await recorder.record(event) })
        }
        try await establishConnection(transport, workingDirectory: "/tmp/project")
        _ = await transport.nextSentMessage()
        _ = await recorder.nextEvent()
        let requestID = ACPRequestID.string("permission")
        try await transport.feed(permissionRequest(id: requestID))
        guard case let .permissionRequested(permission) = await recorder.nextEvent() else {
            Issue.record("Expected permission request")
            return
        }

        await runner.resolvePermission(
            turnToken: permission.turnToken,
            requestID: requestID,
            optionID: "once")

        #expect(await transport.nextSentMessage() == .response(
            id: requestID,
            result: .object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string("once"),
                ]),
            ])))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await activeRun.value
        await runner.shutdown()
    }

    @Test func reset_WhenOnlyOneProfileChanges_LeavesOtherConnectionReusable() async throws {
        let firstTransport = FakeACPTransport()
        let secondTransport = FakeACPTransport()
        let factory = RunnerTransportFactory(transports: [firstTransport, secondTransport])
        let runner = ACPAgentRunner(transportFactory: factory)
        let firstID = UUID()
        let secondID = UUID()
        let firstConfiguration = try makeConfiguration()
        let secondConfiguration = try makeConfiguration(workingDirectory: "/tmp/second")

        let firstRun = run(runner, profileID: firstID, configuration: firstConfiguration)
        try await establishConnection(firstTransport, workingDirectory: "/tmp/project")
        _ = await firstTransport.nextSentMessage()
        try await firstTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await firstRun.value
        let secondRun = run(runner, profileID: secondID, configuration: secondConfiguration)
        try await establishConnection(secondTransport, workingDirectory: "/tmp/second")
        _ = await secondTransport.nextSentMessage()
        try await secondTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await secondRun.value

        await runner.reset(profileIDs: [firstID])

        #expect(await firstTransport.observedTerminationCount() == 1)
        #expect(await secondTransport.observedTerminationCount() == 0)
        let reusedRun = run(
            runner,
            profileID: secondID,
            configuration: secondConfiguration,
            prompt: "Reused")
        #expect(await secondTransport.nextSentMessage() == promptRequest(id: 4, text: "Reused"))
        try await secondTransport.feed(promptResponse(id: 4, stopReason: "end_turn"))
        _ = try await reusedRun.value
        await runner.shutdown()
    }

    @Test func run_WhenSessionCacheExceedsBound_EvictsLeastRecentlyUsedConnection() async throws {
        let sessionLimit = ACPAgentRunner.maximumCachedSessions
        #expect(sessionLimit >= 2)
        let transports = (0..<(sessionLimit + 2)).map { _ in FakeACPTransport() }
        let factory = RunnerTransportFactory(transports: transports)
        let runner = ACPAgentRunner(transportFactory: factory)
        let profileIDs = (0...sessionLimit).map { _ in UUID() }
        let configurations = try (0...sessionLimit).map { index in
            try makeConfiguration(workingDirectory: "/tmp/project-\(index)")
        }

        for index in 0..<sessionLimit {
            let activeRun = run(
                runner,
                profileID: profileIDs[index],
                configuration: configurations[index])
            try await establishConnection(
                transports[index],
                workingDirectory: "/tmp/project-\(index)",
                sessionID: "session-\(index)")
            _ = await transports[index].nextSentMessage()
            try await transports[index].feed(promptResponse(id: 3, stopReason: "end_turn"))
            _ = try await activeRun.value
        }

        let reusedRun = run(
            runner,
            profileID: profileIDs[0],
            configuration: configurations[0],
            prompt: "Keep this one")
        #expect(await transports[0].nextSentMessage() == promptRequest(
            id: 4,
            text: "Keep this one",
            sessionID: "session-0"))
        try await transports[0].feed(promptResponse(id: 4, stopReason: "end_turn"))
        _ = try await reusedRun.value

        let overflowRun = run(
            runner,
            profileID: profileIDs[sessionLimit],
            configuration: configurations[sessionLimit])
        try await establishConnection(
            transports[sessionLimit],
            workingDirectory: "/tmp/project-\(sessionLimit)",
            sessionID: "session-\(sessionLimit)")
        _ = await transports[sessionLimit].nextSentMessage()
        try await transports[sessionLimit].feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await overflowRun.value

        #expect(await transports[0].observedTerminationCount() == 0)
        #expect(await transports[1].observedTerminationCount() == 1)
        #expect(await transports[2].observedTerminationCount() == 0)
        #expect(await transports[3].observedTerminationCount() == 0)
        #expect(await transports[sessionLimit].observedTerminationCount() == 0)

        let recorder = RunnerEventRecorder()
        let restoredRun = Task {
            try await runner.run(
                profileID: profileIDs[1],
                configuration: configurations[1],
                prompt: "Continue evicted profile",
                onEvent: { event in await recorder.record(event) })
        }
        try await establishConnection(
            transports[sessionLimit + 1],
            workingDirectory: "/tmp/project-1",
            sessionID: "restored-session")
        _ = await transports[sessionLimit + 1].nextSentMessage()
        try await transports[sessionLimit + 1].feed(promptResponse(
            id: 3,
            stopReason: "end_turn"))
        _ = try await restoredRun.value

        #expect(await recorder.recordedEvents() == [
            .metadata(
                kind: AgentRunMetadataKind.sessionRecovered,
                summary: ACPAgentRunner.sessionEvictionNotice),
            .connected(agentName: "Test Agent", sessionID: "restored-session"),
        ])
        #expect(await transports[2].observedTerminationCount() == 1)

        await runner.shutdown()
    }

    @Test func run_WhenOverflowProfileCannotConnect_PreservesHealthyCachedSessions() async throws {
        let sessionLimit = ACPAgentRunner.maximumCachedSessions
        let transports = (0...sessionLimit).map { _ in FakeACPTransport() }
        let factory = RunnerTransportFactory(transports: transports)
        let runner = ACPAgentRunner(transportFactory: factory)

        for index in 0..<sessionLimit {
            let activeRun = run(
                runner,
                profileID: UUID(),
                configuration: try makeConfiguration(
                    workingDirectory: "/tmp/healthy-\(index)"))
            try await establishConnection(
                transports[index],
                workingDirectory: "/tmp/healthy-\(index)",
                sessionID: "healthy-session-\(index)")
            _ = await transports[index].nextSentMessage()
            try await transports[index].feed(promptResponse(id: 3, stopReason: "end_turn"))
            _ = try await activeRun.value
        }

        let failedRun = run(
            runner,
            profileID: UUID(),
            configuration: try makeConfiguration(workingDirectory: "/tmp/broken"))
        #expect(await transports[sessionLimit].nextSentMessage() == .request(
            id: .integer(1),
            method: "initialize",
            params: .object([
                "protocolVersion": .integer(1),
                "clientCapabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("voice-activation"),
                    "title": .string("Voice Activation"),
                    "version": .string("0.1.0"),
                ]),
            ])))
        try await transports[sessionLimit].feed(.response(
            id: .integer(1),
            result: .object([
                "protocolVersion": .integer(2),
                "agentCapabilities": .object([:]),
            ])))

        await #expect(throws: ACPClientError.incompatibleProtocol(selected: 2)) {
            try await failedRun.value
        }
        for index in 0..<sessionLimit {
            #expect(await transports[index].observedTerminationCount() == 0)
        }
        #expect(await transports[sessionLimit].observedTerminationCount() == 1)

        await runner.shutdown()
    }

    @Test func reset_WhenTransportCreationIsSuspended_InvalidatesAndDiscardsTheActiveTurn()
        async throws
    {
        let transport = FakeACPTransport()
        let factory = SuspendedRunnerTransportFactory(transport: transport)
        let runner = ACPAgentRunner(transportFactory: factory)
        let profileID = UUID()
        let activeRun = run(
            runner,
            profileID: profileID,
            configuration: try makeConfiguration())
        await factory.waitUntilRequested()

        await runner.reset(profileIDs: [profileID])
        await factory.resume()

        await #expect(throws: ACPAgentRunnerError.cancelled) {
            try await activeRun.value
        }
        #expect(await transport.observedTerminationCount() == 1)
        await runner.shutdown()
    }

    @Test func diagnostics_WhenChunkExceedsLimit_PublishesOnlyNewestSixteenKiB() async throws {
        let transport = FakeACPTransport()
        let runner = ACPAgentRunner(
            transportFactory: RunnerTransportFactory(transports: [transport]))
        let recorder = RunnerEventRecorder()
        let activeRun = Task {
            try await runner.run(
                profileID: UUID(),
                configuration: try makeConfiguration(),
                prompt: "Inspect",
                onEvent: { event in await recorder.record(event) })
        }
        try await establishConnection(transport, workingDirectory: "/tmp/project")
        _ = await transport.nextSentMessage()
        _ = await recorder.nextEvent()

        await transport.feedDiagnostic("old-marker" + String(repeating: "n", count: 20_000))

        guard case let .deliveryNotice(notice) = await recorder.nextEvent() else {
            Issue.record("Expected a typed truncation notice")
            return
        }
        #expect(notice.kind == .diagnosticTruncated)
        #expect(notice.discardedBytes == 3_626)
        guard case let .diagnostic(message) = await recorder.nextEvent() else {
            Issue.record("Expected bounded stderr diagnostic")
            return
        }
        #expect(message.utf8.count == ACPAgentRunner.maximumStandardErrorBytes)
        #expect(!message.contains("old-marker"))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await activeRun.value
        await runner.shutdown()
    }

    @Test func processExit_WhenFinalReadsArriveAfterExitObservation_ForwardsThemBeforeRunEnds()
        async throws
    {
        let transport = FakeACPTransport()
        let runner = ACPAgentRunner(
            transportFactory: RunnerTransportFactory(transports: [transport]))
        let recorder = RunnerEventRecorder()
        let profileID = UUID()
        let activeRun = Task {
            try await runner.run(
                profileID: profileID,
                configuration: try makeConfiguration(),
                prompt: "Inspect",
                onEvent: { event in await recorder.record(event) })
        }
        try await establishConnection(transport, workingDirectory: "/tmp/project")
        _ = await transport.nextSentMessage()
        _ = await recorder.nextEvent()

        await transport.reportExit(status: 0)
        for _ in 0..<20 {
            await Task.yield()
        }
        try await transport.feed(agentMessageUpdate(text: "final output"))
        await transport.feedDiagnostic("final stderr 🧪")
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        await transport.finishStreams()

        #expect(try await activeRun.value == AgentRunResult(stopReason: .endTurn))
        let events = await recorder.recordedEvents()
        #expect(events.contains(.agentMessageDelta(messageID: nil, text: "final output")))
        #expect(events.contains(.diagnostic("final stderr 🧪")))
        await runner.shutdown()
    }

    @Test func run_WhenResponsePrecedesFinalDiagnosticAndExit_SettlesTheOriginalTurn()
        async throws
    {
        let firstTransport = FakeACPTransport()
        let secondTransport = FakeACPTransport()
        let settleClock = ManualACPAgentRunnerClock()
        let runner = ACPAgentRunner(
            transportFactory: RunnerTransportFactory(
                transports: [firstTransport, secondTransport]),
            settleClock: settleClock)
        let profileID = UUID()
        let configuration = try makeConfiguration()
        let firstRecorder = RunnerEventRecorder()
        let firstRun = Task {
            try await runner.run(
                profileID: profileID,
                configuration: configuration,
                prompt: "First",
                onEvent: { event in await firstRecorder.record(event) })
        }
        try await establishConnection(firstTransport, workingDirectory: "/tmp/project")
        _ = await firstTransport.nextSentMessage()
        _ = await firstRecorder.nextEvent()

        try await firstTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        await settleClock.waitUntilSleeping()
        await firstTransport.feedDiagnostic("final stderr")
        await firstTransport.reportExit(status: 0)
        await firstTransport.finishStreams()

        #expect(try await firstRun.value == AgentRunResult(stopReason: .endTurn))
        #expect(await firstRecorder.recordedEvents().contains(.diagnostic("final stderr")))

        let secondRecorder = RunnerEventRecorder()
        let secondRun = Task {
            try await runner.run(
                profileID: profileID,
                configuration: configuration,
                prompt: "Second",
                onEvent: { event in await secondRecorder.record(event) })
        }
        try await establishConnection(secondTransport, workingDirectory: "/tmp/project")
        _ = await secondTransport.nextSentMessage()
        _ = await secondRecorder.nextEvent()
        try await secondTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        await settleClock.waitUntilSleeping()
        await settleClock.advance()

        #expect(try await secondRun.value == AgentRunResult(stopReason: .endTurn))
        let secondEvents = await secondRecorder.recordedEvents()
        #expect(!secondEvents.contains(.diagnostic("final stderr")))
        await runner.shutdown()
    }

    @Test func run_WhenExitResolvesDuringSettledLatchCancellation_DrainsOriginalTurn()
        async throws
    {
        let transport = FakeACPTransport()
        let settleClock = ManualACPAgentRunnerClock()
        let drainClock = ManualACPAgentRunnerClock()
        let cancellationGate = RunnerPromptSettleCancellationGate()
        let runner = ACPAgentRunner(
            transportFactory: RunnerTransportFactory(transports: [transport]),
            drainClock: drainClock,
            settleClock: settleClock,
            testingHooks: ACPAgentRunnerTestingHooks(
                beforeCancelledExitWaitReturns: { await cancellationGate.pause() }))
        let recorder = RunnerEventRecorder()
        let activeRun = Task {
            try await runner.run(
                profileID: UUID(),
                configuration: try makeConfiguration(),
                prompt: "Inspect",
                onEvent: { event in await recorder.record(event) })
        }
        try await establishConnection(transport, workingDirectory: "/tmp/project")
        _ = await transport.nextSentMessage()
        _ = await recorder.nextEvent()

        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        await settleClock.waitUntilSleeping()
        await settleClock.advance()
        await cancellationGate.waitUntilPaused()
        await transport.reportExit(status: 0)
        await drainClock.waitUntilSleeping()
        await cancellationGate.open()
        for _ in 0..<100 {
            await Task.yield()
        }
        await transport.feedDiagnostic("final stderr during exit")
        await transport.finishStreams()

        #expect(try await activeRun.value == AgentRunResult(stopReason: .endTurn))
        #expect(
            await recorder.recordedEvents().contains(
                .diagnostic("final stderr during exit")))
        await runner.shutdown()
    }

    @Test func run_WhenHealthyPromptSettlementIsCancelled_DoesNotAwaitProcessExit()
        async throws
    {
        let transport = FakeACPTransport()
        let settleClock = DelayedCancellationACPAgentRunnerClock()
        let completion = RunnerCompletionObservation()
        let runner = ACPAgentRunner(
            transportFactory: RunnerTransportFactory(transports: [transport]),
            settleClock: settleClock)
        let activeRun = Task {
            let result = try await runner.run(
                profileID: UUID(),
                configuration: try makeConfiguration(),
                prompt: "Inspect",
                onEvent: { _ in })
            await completion.complete()
            return result
        }
        try await establishConnection(transport, workingDirectory: "/tmp/project")
        _ = await transport.nextSentMessage()

        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        await settleClock.waitUntilSleeping()
        activeRun.cancel()
        try await ContinuousClock().sleep(for: .milliseconds(250))
        let completedBeforeExit = await completion.completed()
        if !completedBeforeExit {
            await transport.reportExit(status: 0)
            await transport.finishStreams()
        }

        #expect(completedBeforeExit)
        #expect(try await activeRun.value == AgentRunResult(stopReason: .endTurn))
        await runner.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func processExit_WhenReadPipeNeverReachesEOF_ClosesConnectionAfterDrainGrace() async throws {
        let firstTransport = FakeACPTransport()
        let secondTransport = FakeACPTransport()
        let clock = ManualACPAgentRunnerClock()
        let runner = ACPAgentRunner(
            transportFactory: RunnerTransportFactory(
                transports: [firstTransport, secondTransport]),
            drainClock: clock)
        let profileID = UUID()
        let configuration = try makeConfiguration()
        let activeRun = run(runner, profileID: profileID, configuration: configuration)
        try await establishConnection(firstTransport, workingDirectory: "/tmp/project")
        _ = await firstTransport.nextSentMessage()

        await firstTransport.reportExit(status: 0)
        await clock.waitUntilSleeping()
        await clock.advance()

        await #expect(throws: ACPClientError.connectionClosed) {
            try await activeRun.value
        }
        #expect(await firstTransport.observedReadStreamCloseCount() == 1)

        let replacement = run(runner, profileID: profileID, configuration: configuration)
        try await establishConnection(secondTransport, workingDirectory: "/tmp/project")
        _ = await secondTransport.nextSentMessage()
        try await secondTransport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await replacement.value
        await runner.shutdown()
    }

    @Test func diagnostics_WhenHandlerIsStalled_KeepsPendingBytesBounded() async throws {
        let transport = FakeACPTransport()
        let runner = ACPAgentRunner(
            transportFactory: RunnerTransportFactory(transports: [transport]))
        let gate = RunnerEventGate()
        let profileID = UUID()
        let activeRun = Task {
            try await runner.run(
                profileID: profileID,
                configuration: try makeConfiguration(),
                prompt: "Inspect",
                onEvent: { _ in await gate.wait() })
        }
        try await establishConnection(transport, workingDirectory: "/tmp/project")
        _ = await transport.nextSentMessage()

        for index in 0..<64 {
            await transport.feedDiagnostic(String(repeating: "\(index % 10)", count: 4_096))
        }
        while await runner.retainedStandardErrorByteCountForTesting(profileID: profileID)
            < ACPAgentRunner.maximumStandardErrorBytes
        {
            await Task.yield()
        }

        #expect(
            await runner.pendingDiagnosticByteCountForTesting()
                <= ACPAgentRunner.maximumStandardErrorBytes)

        await gate.open()
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await activeRun.value
        await runner.shutdown()
    }

    @Test func diagnostics_WhenUTF8ScalarIsSplitAcrossReads_DecodesItExactlyOnce() async throws {
        let transport = FakeACPTransport()
        let runner = ACPAgentRunner(
            transportFactory: RunnerTransportFactory(transports: [transport]))
        let recorder = RunnerEventRecorder()
        let activeRun = Task {
            try await runner.run(
                profileID: UUID(),
                configuration: try makeConfiguration(),
                prompt: "Inspect",
                onEvent: { event in await recorder.record(event) })
        }
        try await establishConnection(transport, workingDirectory: "/tmp/project")
        _ = await transport.nextSentMessage()
        _ = await recorder.nextEvent()

        for byte in "🧪".utf8 {
            await transport.feedDiagnostic(Data([byte]))
        }

        #expect(await recorder.nextEvent() == .diagnostic("🧪"))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await activeRun.value
        await runner.shutdown()
    }

    private func run(
        _ runner: ACPAgentRunner,
        profileID: UUID,
        configuration: AgentHarnessConfiguration,
        prompt: String = "First") -> Task<AgentRunResult, any Error>
    {
        Task {
            try await runner.run(
                profileID: profileID,
                configuration: configuration,
                prompt: prompt,
                onEvent: { _ in })
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool) async -> Bool
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func establishConnection(
        _ transport: FakeACPTransport,
        workingDirectory: String,
        sessionID: String = "session-1") async throws
    {
        #expect(await transport.nextSentMessage() == .request(
            id: .integer(1),
            method: "initialize",
            params: .object([
                "protocolVersion": .integer(1),
                "clientCapabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("voice-activation"),
                    "title": .string("Voice Activation"),
                    "version": .string("0.1.0"),
                ]),
            ])))
        try await transport.feed(.response(
            id: .integer(1),
            result: .object([
                "protocolVersion": .integer(1),
                "agentCapabilities": .object([:]),
                "agentInfo": .object([
                    "name": .string("test-agent"),
                    "title": .string("Test Agent"),
                    "version": .string("1.0.0"),
                ]),
                "authMethods": .array([]),
            ])))
        #expect(await transport.nextSentMessage() == .request(
            id: .integer(2),
            method: "session/new",
            params: .object([
                "cwd": .string(workingDirectory),
                "mcpServers": .array([]),
            ])))
        try await transport.feed(.response(
            id: .integer(2),
            result: .object(["sessionId": .string(sessionID)])))
    }

    private func makeConfiguration(
        workingDirectory: String = "/tmp/project") throws -> AgentHarnessConfiguration
    {
        try AgentHarnessConfiguration(
            preset: .codex,
            displayName: "Configured Agent",
            executablePath: "/usr/bin/agent",
            arguments: ["acp"],
            workingDirectory: workingDirectory,
            permissionPolicy: .ask)
    }

    private func promptRequest(
        id: Int64,
        text: String,
        sessionID: String = "session-1") -> ACPMessage
    {
        .request(
            id: .integer(id),
            method: "session/prompt",
            params: .object([
                "sessionId": .string(sessionID),
                "prompt": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(ACPClientConnection.markdownPresentationInstruction),
                    ]),
                    .object([
                        "type": .string("text"),
                        "text": .string(text),
                    ]),
                ]),
            ]))
    }

    private func promptResponse(id: Int64, stopReason: String) -> ACPMessage {
        .response(
            id: .integer(id),
            result: .object(["stopReason": .string(stopReason)]))
    }

    private func permissionRequest(id: ACPRequestID) -> ACPMessage {
        .request(
            id: id,
            method: "session/request_permission",
            params: .object([
                "sessionId": .string("session-1"),
                "toolCall": .object([
                    "toolCallId": .string("tool-1"),
                    "title": .string("Edit"),
                    "kind": .string("edit"),
                    "status": .string("pending"),
                ]),
                "options": .array([
                    .object([
                        "optionId": .string("once"),
                        "name": .string("Allow once"),
                        "kind": .string("allow_once"),
                    ]),
                ]),
            ]))
    }

    private func agentMessageUpdate(text: String) -> ACPMessage {
        .notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("session-1"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(text),
                    ]),
                ]),
            ]))
    }

    private func modeUpdate(id: String) -> ACPMessage {
        .notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("session-1"),
                "update": .object([
                    "sessionUpdate": .string("current_mode_update"),
                    "currentModeId": .string(id),
                ]),
            ]))
    }

    private func isSessionCreation(_ message: ACPMessage) -> Bool {
        guard case let .request(_, method, _) = message else {
            return false
        }
        return method == "session/new"
    }
}

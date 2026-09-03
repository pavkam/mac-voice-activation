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
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
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

    private func cancel(id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume()
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

    private func establishConnection(
        _ transport: FakeACPTransport,
        workingDirectory: String) async throws
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
            result: .object(["sessionId": .string("session-1")])))
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

    private func promptRequest(id: Int64, text: String) -> ACPMessage {
        .request(
            id: .integer(id),
            method: "session/prompt",
            params: .object([
                "sessionId": .string("session-1"),
                "prompt": .array([
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

    private func isSessionCreation(_ message: ACPMessage) -> Bool {
        guard case let .request(_, method, _) = message else {
            return false
        }
        return method == "session/new"
    }
}

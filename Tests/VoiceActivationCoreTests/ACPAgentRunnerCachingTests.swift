// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore


extension ACPAgentRunnerTests {
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

}

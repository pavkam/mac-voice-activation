// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore


extension ACPAgentRunnerTests {
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

}

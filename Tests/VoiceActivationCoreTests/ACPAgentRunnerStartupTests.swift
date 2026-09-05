// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore


extension ACPAgentRunnerTests {
    @Test func run_WhenEventIsDelivered_RecordsPriorityAndHandlerDuration() async throws {
        let transport = FakeACPTransport()
        let factory = RunnerTransportFactory(transports: [transport])
        let diagnostics = RunnerDiagnosticRecorder()
        let runner = ACPAgentRunner(
            transportFactory: factory,
            diagnostics: diagnostics)
        let profileID = UUID()
        let configuration = try makeConfiguration()

        let activeRun = run(runner, profileID: profileID, configuration: configuration)
        try await establishConnection(transport, workingDirectory: "/tmp/project")
        #expect(await transport.nextSentMessage() == promptRequest(id: 3, text: "First"))
        try await transport.feed(agentMessageUpdate(text: "Hello."))
        try await transport.feed(promptResponse(id: 3, stopReason: "end_turn"))
        _ = try await activeRun.value

        let entries = diagnostics.snapshot().filter {
            $0.fields["event_kind"] == "agent_message_delta"
        }
        let admission = entries.first { $0.event == "acp_runner.event_admitted" }
        let started = entries.first { $0.event == "acp_runner.delivery_handler_started" }
        let finished = entries.first { $0.event == "acp_runner.delivery_handler_finished" }
        #expect(admission?.fields["task_priority"] != nil)
        #expect(
            Int(started?.fields["task_priority"] ?? "") ?? 0
                >= TaskPriority.userInitiated.rawValue)
        #expect(finished?.fields["duration_ms"] != nil)

        await runner.shutdown()
    }

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

}

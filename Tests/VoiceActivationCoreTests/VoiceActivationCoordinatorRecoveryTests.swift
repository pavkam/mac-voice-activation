// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore


extension VoiceActivationCoordinatorTests {
    @MainActor @Test func execution_WhenAgentFails_PublishesFailureAndResumesPassive() async throws {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        var states: [ActivationState] = []
        var lifecycleEvents: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onStateChange = { states.append($0) }
        fixture.coordinator.onAgentRunEvent = { lifecycleEvents.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent fail", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }

        await fixture.agentRunner.fail(
            runIndex: 0,
            error: ControlledAgentRunnerError.runFailed)
        await waitUntil { fixture.coordinator.state == .listening }

        #expect(states.contains(.failed("The fake agent run failed.")))
        guard case let .started(runID, _, _) = lifecycleEvents.first else {
            Issue.record("Expected an agent run start")
            return
        }
        #expect(lifecycleEvents.last == .failed(
            runID: runID,
            message: "The fake agent run failed."))
        #expect(fixture.speech.mode == .passiveWake)
    }

    @MainActor
    @Test func execution_WhenAgentFailsAfterActivity_KeepsConversationOpenForRecovery()
        async throws
    {
        let fixture = try Fixture(timing: .fast, profiles: [try makeAgentProfile()])
        var lifecycleEvents: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { lifecycleEvents.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent inspect", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 1 }
        await fixture.agentRunner.emit(
            .agentMessageDelta(messageID: "progress", text: "I found useful output."),
            from: 0)

        await fixture.agentRunner.fail(
            runIndex: 0,
            error: ControlledAgentRunnerError.runFailed)
        await waitUntil {
            lifecycleEvents.contains { event in
                if case .turnFailed = event { return true }
                return false
            }
        }

        guard case let .started(runID, _, _) = lifecycleEvents.first else {
            Issue.record("Expected an agent run start")
            return
        }
        #expect(lifecycleEvents.last == .turnFailed(
            runID: runID,
            message: "The fake agent run failed."))
        #expect(fixture.coordinator.state == .executing)

        fixture.speech.emit("continue from there", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 2 }
        #expect(await fixture.agentRunner.recordedInvocations().map(\.prompt) == [
            "inspect", "continue from there",
        ])
        await fixture.agentRunner.complete(runIndex: 1)
    }

    @MainActor @Test func agentCompletion_WhenNewerAgentIsRunning_DoesNotCleanUpNewExecution() async throws {
        let profile = try makeAgentProfile()
        let fixture = try Fixture(profiles: [profile])
        var lifecycleEvents: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { lifecycleEvents.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent first", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }
        fixture.coordinator.pushToTalkPressed(profileID: profile.id)
        fixture.speech.emit("second")
        fixture.coordinator.pushToTalkReleased()
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 2
        }

        let conversationRunIDs = lifecycleEvents.compactMap { event -> UUID? in
            guard case let .started(runID, _, _) = event else { return nil }
            return runID
        }
        #expect(conversationRunIDs.count == 1)
        guard let conversationRunID = conversationRunIDs.first else {
            Issue.record("Expected one conversation run identifier")
            return
        }
        #expect(lifecycleEvents.contains(.followUpSubmitted(
            runID: conversationRunID,
            prompt: "second")))
        #expect(lifecycleEvents.contains(.turnStarted(runID: conversationRunID)))

        await fixture.agentRunner.complete(runIndex: 0)
        try await Task.sleep(for: .milliseconds(30))

        #expect(fixture.coordinator.state == .executing)
        #expect(fixture.speech.startCount == 4)
        #expect(fixture.speech.mode == .conversation)

        await fixture.agentRunner.complete(runIndex: 1)
        await waitUntil { fixture.coordinator.state == .executing }
        #expect(fixture.speech.startCount == 4)
        fixture.coordinator.endAgentConversation()
        await waitUntil { fixture.coordinator.state == .listening }
    }

    @MainActor @Test func commandCompletion_WhenNewerCommandIsRunning_IgnoresOlderCompletion() async throws {
        let speech = FakeSpeechSession()
        let runner = ControlledCommandRunner()
        let template = try CommandTemplate(
            executablePath: "/usr/bin/printf",
            argumentTemplates: ["{text}"])
        let coordinator = VoiceActivationCoordinator(
            speechSession: speech,
            commandRunner: runner,
            configuration: {
                ActivationConfiguration(
                    wakePhrase: "computer",
                    localeID: "en-US",
                    commandTemplate: template)
            },
            timing: .fast)
        coordinator.setPassiveEnabled(true)
        speech.emit("computer first", isFinal: true)
        await waitUntil {
            await runner.recordedTranscripts() == ["first"]
        }

        coordinator.pushToTalkPressed()
        speech.emit("second")
        coordinator.pushToTalkReleased()
        await waitUntil {
            await runner.recordedTranscripts() == ["first", "second"]
        }
        await runner.completeNext()
        try await Task.sleep(for: .milliseconds(30))

        #expect(coordinator.state == .executing)
        #expect(speech.mode == nil)

        await runner.completeNext()
        await waitUntil {
            coordinator.state == .listening && speech.mode == .passiveWake
        }
    }

    @MainActor @Test func passiveRestart_WhenPushToTalkCommandStarts_DoesNotPreemptCommand() async throws {
        let speech = FakeSpeechSession()
        let runner = ControlledCommandRunner()
        let template = try CommandTemplate(
            executablePath: "/usr/bin/printf",
            argumentTemplates: ["{text}"])
        let coordinator = VoiceActivationCoordinator(
            speechSession: speech,
            commandRunner: runner,
            configuration: {
                ActivationConfiguration(
                    wakePhrase: "computer",
                    localeID: "en-US",
                    commandTemplate: template)
            },
            timing: .pendingPassiveRestart)
        coordinator.setPassiveEnabled(true)
        speech.emitError("recognizer interrupted")

        coordinator.pushToTalkPressed()
        speech.emit("new command")
        coordinator.pushToTalkReleased()
        await waitUntil {
            await runner.recordedTranscripts() == ["new command"]
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(coordinator.state == .executing)
        #expect(speech.mode == nil)

        await runner.completeNext()
        await waitUntil {
            coordinator.state == .listening && speech.mode == .passiveWake
        }
    }

}

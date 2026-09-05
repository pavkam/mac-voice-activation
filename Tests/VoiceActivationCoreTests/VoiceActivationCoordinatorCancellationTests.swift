// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore


extension VoiceActivationCoordinatorTests {
    @MainActor @Test func cancelAgentRun_WhenAgentIsExecuting_CancelsTurnAndKeepsConversationListening() async throws {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        var lifecycleEvents: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { lifecycleEvents.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent cancel this", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }

        fixture.coordinator.cancelAgentRun()
        fixture.coordinator.cancelAgentRun()
        await waitUntil {
            await fixture.agentRunner.cancelCount == 1 && lifecycleEvents.count == 3
        }
        await fixture.agentRunner.emit(.diagnostic("too late"), from: 0)
        await fixture.agentRunner.complete(runIndex: 0)
        try await Task.sleep(for: .milliseconds(30))

        #expect(fixture.speech.startCount == 2)
        #expect(fixture.speech.mode == .conversation)
        #expect(fixture.coordinator.state == .executing)
        guard case let .started(runID, _, _) = lifecycleEvents.first else {
            Issue.record("Expected an agent conversation start")
            return
        }
        #expect(lifecycleEvents[1] == .turnCancellationStarted(runID: runID))
        #expect(lifecycleEvents[2] == .turnCompleted(
            runID: runID,
            result: AgentRunResult(stopReason: .cancelled)))
    }

    @MainActor @Test func stop_WhenAgentIsExecuting_ShutsDownRunnerAndIgnoresLateEvents() async throws {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        var lifecycleEvents: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { lifecycleEvents.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent stop this", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }

        fixture.coordinator.stop()
        await waitUntil { await fixture.agentRunner.shutdownCount == 1 }
        await fixture.agentRunner.emit(.diagnostic("too late"), from: 0)
        await fixture.agentRunner.complete(runIndex: 0)
        try await Task.sleep(for: .milliseconds(30))

        #expect(lifecycleEvents.count == 1)
        #expect(fixture.coordinator.state == .disabled)
        #expect(fixture.speech.mode == nil)
    }

    @MainActor @Test func pushToTalk_WhenAgentProfileIsSelected_RoutesToThatHarness() async throws {
        let firstProfile = try makeAgentProfile(displayName: "First")
        let selectedProfile = try makeAgentProfile(displayName: "Selected")
        let fixture = try Fixture(profiles: [firstProfile, selectedProfile])

        fixture.coordinator.pushToTalkPressed(profileID: selectedProfile.id)
        fixture.speech.emit("fix the tests")
        fixture.coordinator.pushToTalkReleased()
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }

        let invocation = await fixture.agentRunner.recordedInvocations()[0]
        #expect(invocation.profileID == selectedProfile.id)
        #expect(invocation.configuration.displayName == "Selected")
        #expect(invocation.prompt == "fix the tests")
        await fixture.agentRunner.complete(runIndex: 0)
    }

    @MainActor @Test func cancelAgentRun_WhenCalledBeforeRunnerEntry_DoesNotStartAgent() async throws {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        var lifecycleEvents: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { lifecycleEvents.append($0) }
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("agent never start", isFinal: true)
        fixture.coordinator.cancelAgentRun()
        await waitUntil {
            await fixture.agentRunner.cancelCount == 1
                && lifecycleEvents.count == 3
        }

        #expect(await fixture.agentRunner.recordedInvocations().isEmpty)
        #expect(fixture.speech.startCount == 2)
        #expect(fixture.speech.mode == .conversation)
        #expect(fixture.coordinator.state == .executing)
    }

    @MainActor @Test func stop_WhenCalledBeforeRunnerEntry_DoesNotStartAgent() async throws {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("agent never start", isFinal: true)
        fixture.coordinator.stop()
        await waitUntil { await fixture.agentRunner.shutdownCount == 1 }

        #expect(await fixture.agentRunner.recordedInvocations().isEmpty)
        #expect(fixture.coordinator.state == .disabled)
    }

    @MainActor @Test func cancelAgentRun_WhenCoordinatorIsIdle_IsANoOp() async throws {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])

        fixture.coordinator.cancelAgentRun()
        try await Task.sleep(for: .milliseconds(20))

        #expect(await fixture.agentRunner.cancelCount == 0)
        #expect(fixture.speech.startCount == 0)
        #expect(fixture.coordinator.state == .disabled)
    }

    @MainActor @Test func cancelAgentRun_WhenCommandIsExecuting_IsANoOp() async throws {
        let speech = FakeSpeechSession()
        let commandRunner = ControlledCommandRunner()
        let agentRunner = ControlledAgentRunner()
        let profile = try WakeProfile(
            wakePhrase: "computer",
            urlTemplate: "https://example.com/?q={urlText}",
            accent: .blue)
        let coordinator = VoiceActivationCoordinator(
            speechSession: speech,
            commandRunner: commandRunner,
            agentRunner: agentRunner,
            configuration: {
                ActivationConfiguration(profiles: [profile], localeID: "en-US")
            },
            timing: .fast)
        coordinator.setPassiveEnabled(true)
        speech.emit("computer keep running", isFinal: true)
        await waitUntil {
            await commandRunner.recordedTranscripts() == ["keep running"]
        }

        coordinator.cancelAgentRun()
        try await Task.sleep(for: .milliseconds(20))

        #expect(await agentRunner.cancelCount == 0)
        #expect(coordinator.state == .executing)
        #expect(speech.startCount == 1)

        await commandRunner.completeNext()
        await waitUntil { coordinator.state == .listening }
    }

    @MainActor
    @Test func pushToTalk_WhenConversationIsActiveAndReleasedEmpty_ResumesLiveListeningWithoutCancelling() async throws {
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
        fixture.coordinator.pushToTalkReleased()
        try await Task.sleep(for: .milliseconds(30))

        #expect(fixture.coordinator.state == .executing)
        #expect(fixture.speech.mode == .conversation)
        #expect(fixture.speech.startCount == 4)
        #expect(await fixture.agentRunner.cancelCount == 0)
        #expect(lifecycleEvents.count == 1)
        await fixture.agentRunner.complete(runIndex: 0)
        fixture.coordinator.endAgentConversation()
        await waitUntil { fixture.speech.mode == .passiveWake }
    }

    @MainActor
    @Test func pushToTalk_WhenCancellationIsSpoken_EndsConversation() async throws {
        let profile = try makeAgentProfile()
        let fixture = try Fixture(profiles: [profile])
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent first", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }
        await fixture.agentRunner.delayCancellation()

        fixture.coordinator.pushToTalkPressed(profileID: profile.id)
        fixture.speech.emit("cancel", isFinal: true)
        await waitUntil { await fixture.agentRunner.cancelCount == 1 }
        try await Task.sleep(for: .milliseconds(30))

        #expect(fixture.coordinator.state == .executing)
        #expect(fixture.speech.mode == nil)

        await fixture.agentRunner.releaseCancellation()
        await waitUntil {
            fixture.coordinator.state == .listening
                && fixture.speech.mode == .passiveWake
        }

        #expect(fixture.speech.mode == .passiveWake)
        await fixture.agentRunner.complete(runIndex: 0)
    }

    @MainActor
    @Test func pushToTalk_WhenAgentInterruptionIsBlocked_QueuesFollowUpInSameConversation() async throws {
        let profile = try makeAgentProfile()
        let fixture = try Fixture(profiles: [profile])
        var lifecycleEvents: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { lifecycleEvents.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent first", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }
        await fixture.agentRunner.delayCancellation()

        fixture.coordinator.pushToTalkPressed(profileID: profile.id)
        fixture.speech.emit("second")
        fixture.coordinator.pushToTalkReleased()
        await waitUntil { await fixture.agentRunner.cancelCount == 1 }
        try await Task.sleep(for: .milliseconds(30))

        #expect(await fixture.agentRunner.recordedInvocations().count == 1)
        #expect(lifecycleEvents.count == 3)

        await fixture.agentRunner.releaseCancellation()
        await waitUntil(timeout: .milliseconds(500)) {
            await fixture.agentRunner.recordedInvocations().count == 2
                && lifecycleEvents.count == 4
        }

        guard
            case let .started(firstRunID, _, firstPrompt) = lifecycleEvents[0],
            case let .followUpSubmitted(followUpRunID, secondPrompt) = lifecycleEvents[1],
            case let .turnCancellationStarted(cancellationRunID) = lifecycleEvents[2],
            case let .turnStarted(secondRunID) = lifecycleEvents[3]
        else {
            Issue.record("Expected start, queued follow-up, cancellation, then the next turn")
            let invocationCount = await fixture.agentRunner.recordedInvocations().count
            for runIndex in 0..<invocationCount {
                await fixture.agentRunner.complete(runIndex: runIndex)
            }
            return
        }
        #expect(firstPrompt == "first")
        #expect(followUpRunID == firstRunID)
        #expect(cancellationRunID == firstRunID)
        #expect(secondRunID == firstRunID)
        #expect(secondPrompt == "second")

        await fixture.agentRunner.complete(runIndex: 0)
        await fixture.agentRunner.complete(runIndex: 1)
    }

    @MainActor
    @Test func followUps_WhenCancellationIsBlocked_BoundsQueueAndPublishesRejection() async throws {
        let profile = try makeAgentProfile()
        let fixture = try Fixture(profiles: [profile])
        var lifecycleEvents: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { lifecycleEvents.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent first", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }
        await fixture.agentRunner.delayCancellation()

        for index in 0...16 {
            fixture.coordinator.pushToTalkPressed(profileID: profile.id)
            fixture.speech.emit("follow up \(index)")
            fixture.coordinator.pushToTalkReleased()
        }

        let submittedPrompts = lifecycleEvents.compactMap { event -> String? in
            guard case let .followUpSubmitted(_, prompt) = event else { return nil }
            return prompt
        }
        let notices = lifecycleEvents.compactMap { event -> String? in
            guard case let .notice(_, message) = event else { return nil }
            return message
        }
        #expect(submittedPrompts.count == 16)
        #expect(submittedPrompts.first == "follow up 0")
        #expect(submittedPrompts.last == "follow up 15")
        #expect(notices == [
            "Follow-up queue is full. Wait for the agent before speaking again.",
        ])

        fixture.coordinator.stop()
        await fixture.agentRunner.releaseCancellation()
    }

    @MainActor @Test func pushToTalk_WhenAgentIsAlreadyExecuting_CancelsItBeforeStartingNextAgent() async throws {
        let profile = try makeAgentProfile()
        let fixture = try Fixture(profiles: [profile])
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

        #expect(await fixture.agentRunner.cancelCount == 1)
        #expect(await fixture.agentRunner.recordedInvocations().map(\.prompt) == ["first", "second"])
        await fixture.agentRunner.complete(runIndex: 0)
        await fixture.agentRunner.complete(runIndex: 1)
    }

    @MainActor @Test func setPassiveEnabled_WhenConversationIsActive_DoesNotDisturbLiveListening() async throws {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent keep working", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }

        fixture.coordinator.setPassiveEnabled(false)
        fixture.coordinator.setPassiveEnabled(true)
        try await Task.sleep(for: .milliseconds(20))

        #expect(fixture.speech.startCount == 2)
        #expect(fixture.speech.mode == .conversation)
        #expect(await fixture.agentRunner.cancelCount == 0)
        #expect(fixture.coordinator.state == .executing)

        await fixture.agentRunner.complete(runIndex: 0)
        await waitUntil { fixture.coordinator.state == .executing }
        #expect(fixture.speech.startCount == 2)
        #expect(fixture.speech.mode == .conversation)
        fixture.coordinator.endAgentConversation()
        await waitUntil { fixture.coordinator.state == .listening }
    }

    @MainActor @Test func execution_WhenProfileChangesDuringCapture_UsesSnapshottedAgentAction() async throws {
        let profileID = UUID()
        let agentProfile = try makeAgentProfile(id: profileID, displayName: "Captured")
        let commandProfile = try WakeProfile(
            id: profileID,
            wakePhrase: "agent",
            urlTemplate: "https://changed.example/?q={urlText}",
            accent: .orange)
        var profiles = [agentProfile]
        let speech = FakeSpeechSession()
        let commandRunner = RecordingCommandRunner()
        let agentRunner = ControlledAgentRunner()
        let coordinator = VoiceActivationCoordinator(
            speechSession: speech,
            commandRunner: commandRunner,
            agentRunner: agentRunner,
            configuration: {
                ActivationConfiguration(profiles: profiles, localeID: "en-US")
            },
            timing: .fast)
        coordinator.setPassiveEnabled(true)

        speech.emit("agent inspect")
        profiles = [commandProfile]
        speech.emit("agent inspect", isFinal: true)
        await waitUntil { await agentRunner.recordedInvocations().count == 1 }

        #expect(await agentRunner.recordedInvocations()[0].configuration.displayName == "Captured")
        #expect(await commandRunner.recordedTranscripts().isEmpty)
        await agentRunner.complete(runIndex: 0)
    }

}

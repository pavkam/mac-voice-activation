// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import YapOpsCore

extension YapOpsCoordinatorTests {
    @MainActor
    @Test func agentConversation_WhenSteeringRequiresPrompt_QueuesThenStartsAfterCompletion()
        async throws
    {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        await fixture.agentRunner.enqueueMidTurnResults([.promptRequired])
        var events: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { events.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent first", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 1 }

        fixture.speech.emit("second", isFinal: true)
        await waitUntil {
            events.contains { event in
                guard case .followUpDispositionChanged(_, _, .queued) = event else {
                    return false
                }
                return true
            }
        }
        #expect(await fixture.agentRunner.cancelCount == 0)
        #expect(await fixture.agentRunner.recordedInvocations().count == 1)

        await fixture.agentRunner.complete(runIndex: 0)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 2 }
        #expect(await fixture.agentRunner.recordedInvocations().map(\.prompt.request) == [
            "first", "second",
        ])
        #expect(events.contains { event in
            guard case .followUpDispositionChanged(_, _, .prompted) = event else {
                return false
            }
            return true
        })
        await fixture.agentRunner.complete(runIndex: 1)
    }

    @MainActor
    @Test func agentConversation_WhenThreeInputsArrive_PreservesFIFOAcrossSteeringAndPrompts()
        async throws
    {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        await fixture.agentRunner.enqueueMidTurnResults([.injected, .promptRequired])
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent first", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 1 }

        for prompt in ["one", "two", "three"] {
            fixture.speech.emit(prompt, isFinal: true)
        }
        await waitUntil { await fixture.agentRunner.recordedMidTurnOffers().count == 2 }
        #expect(await fixture.agentRunner.recordedMidTurnOffers().map(\.prompt.request) == [
            "one", "two",
        ])

        await fixture.agentRunner.complete(runIndex: 0)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 2 }
        await fixture.agentRunner.complete(runIndex: 1)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 3 }
        #expect(await fixture.agentRunner.recordedInvocations().map(\.prompt.request) == [
            "first", "two", "three",
        ])
        await fixture.agentRunner.complete(runIndex: 2)
    }

    @MainActor
    @Test func agentConversation_WhenSteeringFails_DropsOnlyAmbiguousHeadWithoutReplay()
        async throws
    {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        await fixture.agentRunner.enqueueMidTurnOutcomes([.failure])
        var events: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { events.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent first", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 1 }

        fixture.speech.emit("ambiguous", isFinal: true)
        fixture.speech.emit("safe next", isFinal: true)
        await waitUntil {
            events.contains { event in
                guard case let .notice(_, message) = event else { return false }
                return message == "Delivery failed — say it again."
            }
        }
        #expect(await fixture.agentRunner.recordedMidTurnOffers().map(\.prompt.request) == [
            "ambiguous",
        ])

        await fixture.agentRunner.complete(runIndex: 0)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 2 }
        #expect(await fixture.agentRunner.recordedInvocations().map(\.prompt.request) == [
            "first", "safe next",
        ])
        await fixture.agentRunner.complete(runIndex: 1)
    }

    @MainActor
    @Test func agentConversation_WhenConversationEnds_IgnoresLateRoutingCompletion() async throws {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        await fixture.agentRunner.delayMidTurnOffers()
        var dispositions: [AgentConversationInputDisposition] = []
        var contextInputIDs: [UUID?] = []
        fixture.coordinator.onAgentRunEvent = { event in
            if case .inputContextCaptured(_, let inputID, _) = event {
                contextInputIDs.append(inputID)
            }
            guard case let .followUpDispositionChanged(_, _, disposition) = event else {
                return
            }
            dispositions.append(disposition)
        }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent first", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 1 }
        fixture.speech.emit("late", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedMidTurnOffers().count == 1 }

        fixture.coordinator.endAgentConversation()
        await waitUntil { await fixture.agentRunner.cancelCount == 1 }
        await fixture.agentRunner.releaseMidTurnOffers()
        try await Task.sleep(for: .milliseconds(30))

        #expect(dispositions.isEmpty)
        #expect(contextInputIDs == [nil])
        #expect(fixture.coordinator.agentInputRoutingTask == nil)
        #expect(fixture.coordinator.pendingAgentPrompts.isEmpty)
        await fixture.agentRunner.complete(runIndex: 0)
    }

    @MainActor
    @Test func agentConversation_WhenStopTurnIsClicked_DiscardsQueuedInputAndAcceptsFreshInput()
        async throws
    {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        await fixture.agentRunner.enqueueMidTurnResults([.promptRequired])
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent first", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 1 }
        fixture.speech.emit("next", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedMidTurnOffers().count == 1 }

        fixture.coordinator.cancelAgentRun()
        await waitUntil {
            let cancelCount = await fixture.agentRunner.cancelCount
            return cancelCount == 1 && fixture.coordinator.agentCancellationTask == nil
        }
        #expect(fixture.coordinator.pendingAgentPrompts.isEmpty)
        #expect(await fixture.agentRunner.recordedInvocations().count == 1)
        #expect(fixture.coordinator.resumeAgentConversationListening())
        fixture.speech.emit("fresh request", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 2 }
        #expect(await fixture.agentRunner.recordedInvocations().map(\.prompt.request) == [
            "first", "fresh request",
        ])
        await fixture.agentRunner.complete(runIndex: 0)
        await fixture.agentRunner.complete(runIndex: 1)
    }

    @MainActor
    @Test func agentConversation_WhenPromptFallsBack_ReusesSingleCapturedContext() async throws {
        let target = MacContextTarget(
            processIdentifier: 42,
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari")
        let context = ControlledMacContextCapturer(
            target: target,
            snapshot: makeMacContextSnapshot(target: target))
        let fixture = try Fixture(
            profiles: [try makeAgentProfile()],
            contextCapturer: context)
        await fixture.agentRunner.enqueueMidTurnResults([.promptRequired])
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent first", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 1 }
        fixture.speech.emit("next", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedMidTurnOffers().count == 1 }
        let offeredPrompt = try #require(
            await fixture.agentRunner.recordedMidTurnOffers().first?.prompt)

        await fixture.agentRunner.complete(runIndex: 0)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 2 }
        #expect(await fixture.agentRunner.recordedInvocations()[1].prompt == offeredPrompt)
        #expect(context.currentTargetCallCount == 2)
        #expect(context.capturedTargets.count == 2)
        await fixture.agentRunner.complete(runIndex: 1)
    }

    @MainActor
    @Test func agentConversation_WhenPushToTalkInterrupts_StopsSpeechWithoutCancellingAgentTurn()
        async throws
    {
        let profile = try makeAgentProfile()
        let fixture = try Fixture(profiles: [profile])
        await fixture.agentRunner.enqueueMidTurnResults([.injected])
        var speechCancellationCount = 0
        fixture.coordinator.onAgentSpeechCancellation = {
            speechCancellationCount += 1
        }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent first", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 1 }

        fixture.coordinator.setAgentSpeechOutputActive(true)
        fixture.coordinator.pushToTalkPressed(profileID: profile.id)
        fixture.speech.emit("also check tests", isFinal: true)
        fixture.coordinator.pushToTalkReleased()
        await waitUntil { await fixture.agentRunner.recordedMidTurnOffers().count == 1 }

        #expect(speechCancellationCount == 1)
        #expect(await fixture.agentRunner.cancelCount == 0)
        #expect(await fixture.agentRunner.recordedInvocations().count == 1)
        await fixture.agentRunner.complete(runIndex: 0)
    }

    @MainActor
    @Test func agentConversation_WhenFollowUpExceedsByteLimit_RejectsBeforeCaptureOrOffer()
        async throws
    {
        let context = ControlledMacContextCapturer()
        let fixture = try Fixture(
            profiles: [try makeAgentProfile()],
            contextCapturer: context)
        var notices: [String] = []
        fixture.coordinator.onAgentRunEvent = { event in
            guard case let .notice(_, message) = event else { return }
            notices.append(message)
        }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent first", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 1 }
        let initialTargetCalls = context.currentTargetCallCount
        context.target = MacContextTarget(
            processIdentifier: 42,
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari")

        fixture.speech.emit(
            String(repeating: "é", count: ACPClientConnection.maximumPromptBytes / 2 + 1),
            isFinal: true)
        try await Task.sleep(for: .milliseconds(30))

        #expect(context.currentTargetCallCount == initialTargetCalls)
        #expect(context.capturedTargets.isEmpty)
        #expect(fixture.coordinator.pendingAgentPrompts.isEmpty)
        #expect(await fixture.agentRunner.recordedMidTurnOffers().isEmpty)
        #expect(notices == ["That follow-up is too long. Shorten it and try again."])
        await fixture.agentRunner.complete(runIndex: 0)
    }

    /// A configured terminal phrase, spoken mid-conversation, ends the whole
    /// conversation (not just the current turn) and signals the panel to
    /// close - unlike the UI's "Stop turn" control, which only pauses.
    @MainActor
    @Test func agentConversation_WhenTerminalPhraseIsSpoken_EndsConversationAndSignalsDismissal()
        async throws
    {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        await fixture.agentRunner.enqueueMidTurnResults([.promptRequired])
        var events: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { events.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent first", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 1 }

        fixture.speech.emit("thank you", isFinal: true)

        await waitUntil {
            events.contains { if case .completed = $0 { true } else { false } }
        }
        #expect(events.contains { if case .dismissedBySpeech = $0 { true } else { false } })
        guard case let .dismissedBySpeech(dismissedRunID)? = events.first(where: {
            if case .dismissedBySpeech = $0 { true } else { false }
        }) else {
            Issue.record("expected a dismissedBySpeech event")
            return
        }
        guard case let .completed(completedRunID, result)? = events.first(where: {
            if case .completed = $0 { true } else { false }
        }) else {
            Issue.record("expected a completed event")
            return
        }
        #expect(dismissedRunID == completedRunID)
        #expect(result.stopReason == .cancelled)
        #expect(await fixture.agentRunner.recordedMidTurnOffers().isEmpty)
    }

    /// A ordinary follow-up that merely contains "thanks" mid-sentence must
    /// not be swallowed as a terminal phrase - only the whole utterance counts.
    @MainActor
    @Test func agentConversation_WhenPhraseIsPartOfALongerRequest_IsNotTreatedAsTerminal()
        async throws
    {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        await fixture.agentRunner.enqueueMidTurnResults([.promptRequired])
        var events: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { events.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent first", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedInvocations().count == 1 }

        fixture.speech.emit("thanks for checking that", isFinal: true)
        await waitUntil { await fixture.agentRunner.recordedMidTurnOffers().count == 1 }

        #expect(!events.contains { if case .dismissedBySpeech = $0 { true } else { false } })
        await fixture.agentRunner.complete(runIndex: 0)
    }
}

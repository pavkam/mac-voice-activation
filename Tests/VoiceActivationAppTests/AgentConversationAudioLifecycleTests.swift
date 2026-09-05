// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationApp
@testable import VoiceActivationCore


extension AgentConversationAudioPresenterTests {
    @MainActor @Test
    func orchestrator_WhenWorkAndToolActivityArrive_DelegatesToActivityLoop() {
        let speechQueue = AgentSpeechQueueSpy()
        let activityLoop = AgentActivitySoundLoopSpy()
        let player = AgentConversationAudioOrchestrator(
            speechConfiguration: { .systemDefault },
            speechQueue: speechQueue,
            activityLoop: activityLoop)

        player.setWorking(true)
        player.playActivitySound(.toolStarted)

        #expect(activityLoop.workingStates == [true])
        #expect(activityLoop.sounds == [.toolStarted])
    }

    @MainActor @Test
    func orchestrator_WhenSpeechIsSubmitted_QueuesConfigurationSnapshot() {
        let speechQueue = AgentSpeechQueueSpy()
        let activityLoop = AgentActivitySoundLoopSpy()
        let configuration = AgentSpeechConfiguration(
            provider: .elevenLabs,
            elevenLabsAPIKey: "secret",
            elevenLabsVoiceID: "voice-1")
        let player = AgentConversationAudioOrchestrator(
            speechConfiguration: { configuration },
            speechQueue: speechQueue,
            activityLoop: activityLoop)

        player.speak("  A much better voice.  ", localeID: "en-GB")

        #expect(speechQueue.requests == [AgentSpeechRequest(
            text: "A much better voice.",
            localeID: "en-GB",
            configuration: configuration)])
    }

    @MainActor @Test
    func orchestrator_WhenSpeechIsPreparing_KeepsActivityAudioUnsuppressed() {
        let speechQueue = AgentSpeechQueueSpy()
        let activityLoop = AgentActivitySoundLoopSpy()
        let player = AgentConversationAudioOrchestrator(
            speechConfiguration: { .systemDefault },
            speechQueue: speechQueue,
            activityLoop: activityLoop)

        withExtendedLifetime(player) {
            speechQueue.emit(.preparing)
        }

        #expect(activityLoop.suppressionStates == [false])
    }

    @MainActor @Test
    func orchestrator_WhenPlaybackStarts_StopsActivityBeforeReportingSpeech() {
        let speechQueue = AgentSpeechQueueSpy()
        let activityLoop = AgentActivitySoundLoopSpy()
        let player = AgentConversationAudioOrchestrator(
            speechConfiguration: { .systemDefault },
            speechQueue: speechQueue,
            activityLoop: activityLoop)
        var events: [String] = []
        activityLoop.onSuppression = { events.append("activity:\($0)") }
        player.onSpeakingChange = { events.append("speech:\($0)") }

        speechQueue.emit(.starting)
        speechQueue.emit(.playing)

        #expect(events == [
            "activity:true", "activity:true", "speech:true",
        ])
    }

    @MainActor @Test
    func orchestrator_WhenPlaybackWaitsForAnotherSynthesis_ResumesActivityAndReportsSilence() {
        let speechQueue = AgentSpeechQueueSpy()
        let activityLoop = AgentActivitySoundLoopSpy()
        let player = AgentConversationAudioOrchestrator(
            speechConfiguration: { .systemDefault },
            speechQueue: speechQueue,
            activityLoop: activityLoop)
        var speechStates: [Bool] = []
        player.onSpeakingChange = { speechStates.append($0) }

        speechQueue.emit(.playing)
        speechQueue.emit(.preparing)

        #expect(activityLoop.suppressionStates == [true, false])
        #expect(speechStates == [true, false])
    }

    @MainActor @Test
    func orchestrator_WhenStopped_CancelsBothIndependentPipelines() {
        let speechQueue = AgentSpeechQueueSpy()
        let activityLoop = AgentActivitySoundLoopSpy()
        let player = AgentConversationAudioOrchestrator(
            speechConfiguration: { .systemDefault },
            speechQueue: speechQueue,
            activityLoop: activityLoop)

        player.stopAll()

        #expect(speechQueue.stopCount == 1)
        #expect(activityLoop.stopCount == 1)
    }

    @MainActor @Test func lifecycle_WhenResponseSentencesStream_ReadsEachBeforeTurnCompletes()
        throws
    {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { true },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))

        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer", text: "First sentence.")))

        #expect(player.spoken.map(\.text) == ["First sentence."])

        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer", text: " Second sentence.")))

        #expect(player.spoken.map(\.text) == ["First sentence.", "Second sentence."])

        presenter.handle(.turnCompleted(
            runID: runID,
            result: AgentRunResult(stopReason: .endTurn)))

        #expect(player.spoken.map(\.text) == ["First sentence.", "Second sentence."])
    }

    @MainActor @Test
    func lifecycle_WhenWorkFollowsAnUnpunctuatedMessage_QueuesSpeechBeforeTheWorkCue() throws {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { true },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))

        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(
                messageID: "progress",
                text: "Let me check this")))
        presenter.handle(.event(
            runID: runID,
            event: .toolCall(AgentToolCall(
                id: "read",
                title: "Read files",
                kind: .read,
                status: .inProgress))))

        #expect(player.events == [
            .speech("Let me check this"),
            .activity(.toolStarted),
        ])
        presenter.shutdown()
    }

    @MainActor @Test func lifecycle_WhenOutputPauses_ReadsIncompleteSentenceBeforeTurnCompletes()
        async throws
    {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { true },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))

        await withCheckedContinuation { continuation in
            player.onSpeak = {
                player.onSpeak = nil
                continuation.resume()
            }
            presenter.handle(.event(
                runID: runID,
                event: .agentMessageDelta(
                    messageID: "answer",
                    text: "A useful partial answer")))
            #expect(player.spoken.isEmpty)
        }

        #expect(player.spoken.map(\.text) == ["A useful partial answer"])
    }

    @MainActor @Test func lifecycle_WhenOutputKeepsStreaming_StartsReadingWithoutWaitingForSilence()
        async throws
    {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { true },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))

        for fragment in ["A", " useful", " answer", " keeps", " streaming", " steadily"] {
            presenter.handle(.event(
                runID: runID,
                event: .agentMessageDelta(messageID: "answer", text: fragment)))
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(!player.spoken.isEmpty)
        presenter.shutdown()
    }

    @MainActor @Test func lifecycle_WhenCodeFenceOpensBeforeFlushDeadline_DoesNotFlushTheFence()
        async throws
    {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { false },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))

        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(
                messageID: "answer",
                text: "A short introduction")))
        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(
                messageID: "answer",
                text: "\n```sh\nprivate-command")))
        try await Task.sleep(for: .milliseconds(450))

        #expect(player.spoken.map(\.text) == ["A short introduction"])
        presenter.shutdown()
    }

    @MainActor @Test func lifecycle_WhenFencedCodeStreams_DoesNotReadCodeContents() throws {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { false },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))

        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(
                messageID: "answer",
                text: "Before.\n\n```sh\n")))
        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(
                messageID: "answer",
                text: "dangerous --secret\n")))

        #expect(player.spoken.map(\.text) == ["Before."])

        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(
                messageID: "answer",
                text: "```\nAfter.")))

        #expect(player.spoken.map(\.text) == [
            "Before.", "Code block omitted.", "After.",
        ])
    }

    @MainActor @Test func lifecycle_WhenFencedCodeExceedsSpeechBuffer_RemainsOmitted() throws {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { false },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))

        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(
                messageID: "answer",
                text: "```text\n\(String(repeating: "x", count: 21_000))\n")))

        #expect(player.spoken.isEmpty)

        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer", text: "```\n")))

        #expect(player.spoken.map(\.text) == ["Code block omitted."])
    }

    @MainActor @Test func lifecycle_WhenTurnCompletes_ReadsMarkdownReplyAndTracksWorkingState() throws {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { true },
            localeID: { "en-GB" })
        let runID = UUID()
        let profile = try agentProfile()

        presenter.handle(.started(runID: runID, profile: profile, prompt: "Question"))
        presenter.handle(.event(
            runID: runID,
            event: .thoughtDelta(messageID: "thought", text: "Considering")))
        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer", text: "**Done**")))
        presenter.handle(.turnCompleted(
            runID: runID,
            result: AgentRunResult(stopReason: .endTurn)))

        #expect(player.workingStates == [true, true, true, false])
        #expect(player.spoken.count == 1)
        #expect(player.spoken.first?.text == "Done")
        #expect(player.spoken.first?.localeID == "en-GB")
    }

    @MainActor @Test func lifecycle_WhenActiveTurnFails_ReadsRemainderAndKeepsConversationAudio()
        throws
    {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { true },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))
        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer", text: "Useful remainder")))

        presenter.handle(.turnFailed(runID: runID, message: "Connection closed"))
        presenter.handle(.followUpSubmitted(runID: runID, prompt: "Continue"))

        #expect(player.spoken.map(\.text) == ["Useful remainder"])
        #expect(player.stopAllCount == 0)
        #expect(player.workingStates.suffix(2) == [false, true])
    }

    @MainActor @Test func lifecycle_WhenFollowUpInterruptsTurn_StopsSpeechAndRestartsWorkingCue() throws {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { true },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "First"))
        let previousStopCount = player.stopSpeakingCount

        presenter.handle(.followUpSubmitted(runID: runID, prompt: "Second"))

        #expect(player.stopSpeakingCount == previousStopCount + 1)
        #expect(player.workingStates.last == true)
    }

}

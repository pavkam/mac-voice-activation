// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import AVFoundation
import Testing
@testable import VoiceActivationApp
@testable import VoiceActivationCore

@MainActor
private final class AgentConversationAudioSpy: AgentConversationAudioPlaying {
    var onSpeakingChange: ((Bool) -> Void)?
    var onSpeak: (() -> Void)?
    private(set) var workingStates: [Bool] = []
    private(set) var activitySounds: [AgentActivitySound] = []
    private(set) var spoken: [(text: String, localeID: String)] = []
    private(set) var stopSpeakingCount = 0
    private(set) var stopAllCount = 0

    func setWorking(_ working: Bool) {
        workingStates.append(working)
    }

    func playActivitySound(_ sound: AgentActivitySound) {
        activitySounds.append(sound)
    }

    func speak(_ text: String, localeID: String) {
        spoken.append((text, localeID))
        onSpeak?()
    }

    func stopSpeaking() {
        stopSpeakingCount += 1
    }

    func stopAll() {
        stopAllCount += 1
    }
}

@MainActor
private final class AgentSystemSpeechSynthesizerSpy: AgentSystemSpeechSynthesizing {
    private(set) var utterances: [AVSpeechUtterance] = []
    private(set) var stopCount = 0
    var isSpeaking = false
    var onSpeak: (() -> Void)?

    func speak(_ utterance: AVSpeechUtterance) {
        utterances.append(utterance)
        isSpeaking = true
        onSpeak?()
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopCount += 1
        isSpeaking = false
        return true
    }
}

private actor AgentElevenLabsSpeechSynthesizerSpy: ElevenLabsSpeechSynthesizing {
    private(set) var texts: [String] = []

    func audio(text: String, apiKey: String, voiceID: String) async throws -> Data {
        texts.append(text)
        return Data(text.utf8)
    }
}

private struct AgentElevenLabsSpeechFailure: Error {}

private actor FailingAgentElevenLabsSpeechSynthesizer: ElevenLabsSpeechSynthesizing {
    func audio(text: String, apiKey: String, voiceID: String) async throws -> Data {
        throw AgentElevenLabsSpeechFailure()
    }
}

private actor SuspendedAgentElevenLabsSpeechSynthesizer: ElevenLabsSpeechSynthesizing {
    private var continuation: CheckedContinuation<Data, Never>?

    func audio(text: String, apiKey: String, voiceID: String) async throws -> Data {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume(returning: Data("audio".utf8))
        continuation = nil
    }

    func isWaiting() -> Bool {
        continuation != nil
    }
}

@MainActor
private final class AgentAudioDataPlayerSpy: AgentAudioDataPlaying {
    private(set) var payloads: [Data] = []
    var isPlaying = false
    var onPlay: (() -> Void)?

    func play(_ data: Data) -> Bool {
        payloads.append(data)
        onPlay?()
        return true
    }

    func stop() {
        isPlaying = false
    }
}

@MainActor
private final class AgentActivitySoundPlayerSpy: AgentActivitySoundPlaying {
    private(set) var playCount = 0
    private(set) var sounds: [AgentActivitySound] = []
    private(set) var stopCount = 0
    var onPlay: (() -> Void)?

    func play(_ sound: AgentActivitySound) {
        playCount += 1
        sounds.append(sound)
        onPlay?()
    }

    func stop() {
        stopCount += 1
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AgentConversationAudioPresenterTests {
    @MainActor @Test func systemPlayer_WhenWorkStarts_PlaysThinkingCueImmediately() {
        let activitySounds = AgentActivitySoundPlayerSpy()
        let player = AgentConversationAudioPlayer(
            activitySoundPlayer: activitySounds,
            workingPulseInitialDelay: .seconds(10),
            workingPulseInterval: .seconds(10))

        player.setWorking(true)

        #expect(activitySounds.sounds == [.thinking])
        player.stopAll()
    }

    @MainActor @Test func systemPlayer_WhenWorkingStateRepeats_DoesNotRestartPulseDelay() {
        let activitySounds = AgentActivitySoundPlayerSpy()
        let player = AgentConversationAudioPlayer(activitySoundPlayer: activitySounds)

        player.setWorking(true)
        let stopCountAfterStarting = activitySounds.stopCount
        player.setWorking(true)
        player.setWorking(true)

        #expect(activitySounds.stopCount == stopCountAfterStarting)
        player.stopAll()
    }

    @MainActor @Test func systemPlayer_WhenElevenLabsIsSelected_RoutesSpeechToElevenLabs()
        async
    {
        let systemSynthesizer = AgentSystemSpeechSynthesizerSpy()
        let elevenLabsSynthesizer = AgentElevenLabsSpeechSynthesizerSpy()
        let dataPlayer = AgentAudioDataPlayerSpy()
        let player = AgentConversationAudioPlayer(
            speechSynthesizer: systemSynthesizer,
            speechConfiguration: {
                AgentSpeechConfiguration(
                    provider: .elevenLabs,
                    elevenLabsAPIKey: "secret",
                    elevenLabsVoiceID: "voice-1")
            },
            elevenLabsSynthesizer: elevenLabsSynthesizer,
            elevenLabsAudioPlayer: dataPlayer)

        await withCheckedContinuation { continuation in
            dataPlayer.onPlay = {
                dataPlayer.onPlay = nil
                continuation.resume()
            }
            player.speak("A much better voice.", localeID: "en-US")
        }

        #expect(systemSynthesizer.utterances.isEmpty)
        #expect(await elevenLabsSynthesizer.texts == ["A much better voice."])
        #expect(dataPlayer.payloads == [Data("A much better voice.".utf8)])
        player.stopAll()
    }

    @MainActor @Test func systemPlayer_WhenSpeaking_PausesWorkingPulse() async {
        let systemSynthesizer = AgentSystemSpeechSynthesizerSpy()
        let workingPulse = AgentActivitySoundPlayerSpy()
        let player = AgentConversationAudioPlayer(
            speechSynthesizer: systemSynthesizer,
            activitySoundPlayer: workingPulse,
            workingPulseInitialDelay: .milliseconds(20),
            workingPulseInterval: .seconds(10))

        player.setWorking(true)
        let playCountBeforeSpeaking = workingPulse.playCount
        player.speak("Speaking now.", localeID: "en-US")
        try? await Task.sleep(for: .milliseconds(70))

        #expect(workingPulse.playCount == playCountBeforeSpeaking)

        await withCheckedContinuation { continuation in
            workingPulse.onPlay = {
                workingPulse.onPlay = nil
                continuation.resume()
            }
            systemSynthesizer.isSpeaking = false
        }

        #expect(workingPulse.playCount == playCountBeforeSpeaking + 1)
        player.stopAll()
    }

    @MainActor @Test func systemPlayer_WhenToolCueArrivesDuringSpeech_DoesNotOverlapNarration() {
        let systemSynthesizer = AgentSystemSpeechSynthesizerSpy()
        let activitySounds = AgentActivitySoundPlayerSpy()
        let player = AgentConversationAudioPlayer(
            speechSynthesizer: systemSynthesizer,
            activitySoundPlayer: activitySounds)

        player.speak("Speaking now.", localeID: "en-US")
        player.playActivitySound(.toolStarted)

        #expect(activitySounds.sounds.isEmpty)
        player.stopAll()
    }

    @MainActor @Test func systemPlayer_WhenToolCuePlays_RestartsThinkingDelay() async {
        let activitySounds = AgentActivitySoundPlayerSpy()
        let player = AgentConversationAudioPlayer(
            activitySoundPlayer: activitySounds,
            workingPulseInitialDelay: .milliseconds(120),
            workingPulseInterval: .seconds(10))

        player.setWorking(true)
        try? await Task.sleep(for: .milliseconds(80))
        player.playActivitySound(.toolStarted)
        try? await Task.sleep(for: .milliseconds(70))

        #expect(activitySounds.sounds == [.thinking, .toolStarted])

        await withCheckedContinuation { continuation in
            activitySounds.onPlay = {
                activitySounds.onPlay = nil
                continuation.resume()
            }
        }
        #expect(activitySounds.sounds == [.thinking, .toolStarted, .thinking])
        player.stopAll()
    }

    @MainActor @Test func systemPlayer_WhenCloudSpeechIsStillGenerating_KeepsWorkingPulseAudible()
        async
    {
        let cloudSynthesizer = SuspendedAgentElevenLabsSpeechSynthesizer()
        let workingPulse = AgentActivitySoundPlayerSpy()
        let player = AgentConversationAudioPlayer(
            speechConfiguration: {
                AgentSpeechConfiguration(
                    provider: .elevenLabs,
                    elevenLabsAPIKey: "secret",
                    elevenLabsVoiceID: "voice-1")
            },
            elevenLabsSynthesizer: cloudSynthesizer,
            elevenLabsAudioPlayer: AgentAudioDataPlayerSpy(),
            activitySoundPlayer: workingPulse,
            workingPulseInitialDelay: .milliseconds(20),
            workingPulseInterval: .seconds(10))

        player.setWorking(true)
        player.speak("Generating speech.", localeID: "en-US")
        await waitUntil {
            let cloudRequestIsWaiting = await cloudSynthesizer.isWaiting()
            return workingPulse.playCount == 1 && cloudRequestIsWaiting
        }

        #expect(workingPulse.playCount == 1)
        player.stopAll()
        await cloudSynthesizer.release()
    }

    @MainActor @Test
    func systemPlayer_WhenElevenLabsFails_FallsBackToSystemVoice() async {
        let systemSynthesizer = AgentSystemSpeechSynthesizerSpy()
        let player = AgentConversationAudioPlayer(
            speechSynthesizer: systemSynthesizer,
            speechConfiguration: {
                AgentSpeechConfiguration(
                    provider: .elevenLabs,
                    elevenLabsAPIKey: "secret",
                    elevenLabsVoiceID: "voice-1")
            },
            elevenLabsSynthesizer: FailingAgentElevenLabsSpeechSynthesizer(),
            elevenLabsAudioPlayer: AgentAudioDataPlayerSpy())

        await withCheckedContinuation { continuation in
            systemSynthesizer.onSpeak = {
                systemSynthesizer.onSpeak = nil
                continuation.resume()
            }
            player.speak("Still audible.", localeID: "en-GB")
        }

        #expect(systemSynthesizer.utterances.map(\.speechString) == ["Still audible."])
        #expect(systemSynthesizer.utterances.first?.voice?.language == "en-GB")
        player.stopAll()
    }

    @MainActor @Test func systemPlayer_WhenSpeechChunksQueue_DoesNotInterruptEarlierChunk() {
        let synthesizer = AgentSystemSpeechSynthesizerSpy()
        let player = AgentConversationAudioPlayer(speechSynthesizer: synthesizer)

        player.speak("First sentence.", localeID: "en-US")
        player.speak("Second sentence.", localeID: "en-US")

        #expect(synthesizer.utterances.map(\.speechString) == [
            "First sentence.", "Second sentence.",
        ])
        #expect(synthesizer.stopCount == 0)
        player.stopAll()
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

    @MainActor @Test func lifecycle_WhenToolsTransition_PlaysEachActivityCueOnce() throws {
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
            event: .toolCall(AgentToolCall(
                id: "read",
                title: "Read files",
                kind: .read,
                status: .pending))))
        presenter.handle(.event(
            runID: runID,
            event: .toolCallUpdate(AgentToolCallUpdate(
                id: "read",
                status: .inProgress))))
        presenter.handle(.event(
            runID: runID,
            event: .toolCallUpdate(AgentToolCallUpdate(
                id: "read",
                status: .completed))))
        presenter.handle(.event(
            runID: runID,
            event: .toolCallUpdate(AgentToolCallUpdate(
                id: "read",
                status: .completed))))
        presenter.handle(.event(
            runID: runID,
            event: .toolCall(AgentToolCall(id: "edit", title: "Edit file"))))
        presenter.handle(.event(
            runID: runID,
            event: .toolCallUpdate(AgentToolCallUpdate(
                id: "edit",
                status: .failed))))

        #expect(player.activitySounds == [
            .toolStarted, .toolCompleted, .toolStarted, .toolFailed,
        ])
    }

    @MainActor @Test func lifecycle_WhenActivitySoundsAreDisabled_PlaysNoToolCues() throws {
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
            event: .toolCall(AgentToolCall(id: "tool", title: "Tool"))))
        presenter.handle(.event(
            runID: runID,
            event: .toolCallUpdate(AgentToolCallUpdate(
                id: "tool",
                status: .completed))))

        #expect(player.activitySounds.isEmpty)
    }

    @MainActor @Test func lifecycle_WhenVoiceCancelsConversation_ReadsStoppedAcknowledgement() throws {
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

        presenter.handle(.completed(
            runID: runID,
            result: AgentRunResult(stopReason: .cancelled)))

        #expect(player.spoken.map(\.text) == ["Stopped."])
        #expect(player.spoken.map(\.localeID) == ["en-US"])
    }

    @MainActor @Test func lifecycle_WhenAudioOptionsAreDisabled_ProducesNoPlayback() throws {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { false },
            playsWorkingSound: { false },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))
        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(messageID: nil, text: "Answer")))
        presenter.handle(.turnCompleted(
            runID: runID,
            result: AgentRunResult(stopReason: .endTurn)))

        #expect(player.workingStates.allSatisfy { !$0 })
        #expect(player.spoken.isEmpty)
    }

    @MainActor @Test func lifecycle_WhenPermissionIsRequested_SilencesWorkingCue() throws {
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
        let request = AgentPermissionRequest(
            turnToken: AgentTurnToken(),
            requestID: .integer(4),
            toolCall: AgentToolCallUpdate(
                id: "tool",
                title: "Edit",
                kind: .edit,
                status: .pending),
            options: [])

        presenter.handle(.event(runID: runID, event: .permissionRequested(request)))

        #expect(player.workingStates.last == false)
    }

    @MainActor @Test func permissionResolution_WhenCurrentRunContinues_RestartsWorkingCue() throws {
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
            event: .permissionRequested(AgentPermissionRequest(
                turnToken: AgentTurnToken(),
                requestID: .integer(4),
                toolCall: AgentToolCallUpdate(id: "tool", title: "Edit"),
                options: []))))

        presenter.resumeAfterPermission(runID: runID)

        #expect(player.workingStates.suffix(2) == [false, true])
    }

    @MainActor @Test func refreshSettings_WhenRunHasFailed_DoesNotRestartWorkingCue() throws {
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
        presenter.handle(.failed(runID: runID, message: "Failed"))

        presenter.refreshSettings()

        #expect(player.workingStates.last == false)
    }

    @MainActor @Test func refreshSettings_WhenRepliesAreDisabled_CancelsPendingSpeechFlush()
        async throws
    {
        let player = AgentConversationAudioSpy()
        var readsReplies = true
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { readsReplies },
            playsWorkingSound: { false },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))
        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer", text: "Not yet complete")))

        readsReplies = false
        presenter.refreshSettings()
        try await Task.sleep(for: .milliseconds(450))

        #expect(player.spoken.isEmpty)
    }

    @MainActor
    private func agentProfile() throws -> WakeProfile {
        try WakeProfile(
            wakePhrase: "agent",
            action: .agent(AgentHarnessConfiguration(
                preset: .codex,
                displayName: "Codex",
                executablePath: "/usr/bin/true",
                arguments: [],
                workingDirectory: "/tmp",
                permissionPolicy: .ask)),
            accent: .purple)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () async -> Bool) async
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

}

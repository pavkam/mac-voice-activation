// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationApp

private enum ControlledSpeechError: Error {
    case failed
}

private actor ControlledSpeechSynthesizer: ElevenLabsSpeechSynthesizing {
    private struct Pending {
        let text: String
        let continuation: CheckedContinuation<Data, any Error>
    }

    private(set) var requestedTexts: [String] = []
    private var pending: [Pending] = []

    func audio(text: String, apiKey: String, voiceID: String) async throws -> Data {
        requestedTexts.append(text)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(text: text, continuation: continuation))
        }
    }

    func succeed(_ text: String) {
        guard let index = pending.firstIndex(where: { $0.text == text }) else { return }
        let request = pending.remove(at: index)
        request.continuation.resume(returning: Data(text.utf8))
    }

    func fail(_ text: String) {
        guard let index = pending.firstIndex(where: { $0.text == text }) else { return }
        let request = pending.remove(at: index)
        request.continuation.resume(throwing: ControlledSpeechError.failed)
    }
}

@MainActor
private final class ControlledAudioPlayer: AgentAudioDataPlaying {
    private(set) var payloads: [Data] = []
    private(set) var stopCount = 0
    var acceptsPlayback = true
    private var completion: (@MainActor (Bool) -> Void)?

    func play(
        _ data: Data,
        completion: @escaping @MainActor (Bool) -> Void) -> Bool
    {
        payloads.append(data)
        guard acceptsPlayback else { return false }
        self.completion = completion
        return true
    }

    func finish() {
        let completion = completion
        self.completion = nil
        completion?(true)
    }

    func stop() {
        stopCount += 1
        completion = nil
    }
}

@MainActor
private final class ControlledSystemSpeechPlayer: AgentSystemSpeechPlaying {
    private(set) var texts: [String] = []
    private(set) var localeIDs: [String] = []
    private(set) var stopCount = 0
    private var completion: (@MainActor () -> Void)?

    func play(
        text: String,
        localeID: String,
        completion: @escaping @MainActor () -> Void) -> Bool
    {
        texts.append(text)
        localeIDs.append(localeID)
        self.completion = completion
        return true
    }

    func finish() {
        let completion = completion
        self.completion = nil
        completion?()
    }

    func stop() {
        stopCount += 1
        completion = nil
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AgentSpeechQueueTests {
    @MainActor @Test func enqueue_WhenSystemVoiceIsSelected_WaitsForCompletionBeforeNextSegment() {
        let systemPlayer = ControlledSystemSpeechPlayer()
        let queue = AgentSpeechQueue(
            synthesizer: ControlledSpeechSynthesizer(),
            audioPlayer: ControlledAudioPlayer(),
            systemSpeechPlayer: systemPlayer)

        queue.enqueue(systemRequest("First."))
        queue.enqueue(systemRequest("Second."))
        #expect(systemPlayer.texts == ["First."])

        systemPlayer.finish()
        #expect(systemPlayer.texts == ["First.", "Second."])
        systemPlayer.finish()
        queue.stop()
    }

    @MainActor @Test
    func enqueue_WhenProducerExceedsTheQueueBound_CoalescesTheNewestSpeechWithoutLosingIt() {
        let systemPlayer = ControlledSystemSpeechPlayer()
        let queue = AgentSpeechQueue(
            synthesizer: ControlledSpeechSynthesizer(),
            audioPlayer: ControlledAudioPlayer(),
            systemSpeechPlayer: systemPlayer)

        for index in 0...65 {
            queue.enqueue(systemRequest("Segment \(index)."))
        }
        for _ in 0..<65 {
            systemPlayer.finish()
        }

        #expect(systemPlayer.texts.count == 65)
        #expect(systemPlayer.texts.first == "Segment 0.")
        #expect(systemPlayer.texts.last == "Segment 64. Segment 65.")
        queue.stop()
    }

    @MainActor @Test
    func enqueue_WhenFirstSynthesisIsSuspended_StartsSecondSynthesisIndependently()
        async throws
    {
        let synthesizer = ControlledSpeechSynthesizer()
        let audioPlayer = ControlledAudioPlayer()
        let queue = AgentSpeechQueue(
            synthesizer: synthesizer,
            audioPlayer: audioPlayer,
            systemSpeechPlayer: ControlledSystemSpeechPlayer())
        var states: [AgentSpeechQueueState] = []
        queue.onStateChange = { states.append($0) }

        queue.enqueue(request("First."))
        queue.enqueue(request("Second."))
        try await waitUntil { await synthesizer.requestedTexts.count == 2 }

        #expect(Set(await synthesizer.requestedTexts) == Set(["First.", "Second."]))
        #expect(audioPlayer.payloads.isEmpty)
        #expect(states.last == .preparing)
        queue.stop()
        await synthesizer.succeed("First.")
        await synthesizer.succeed("Second.")
    }

    @MainActor @Test
    func enqueue_WhenSecondSynthesisFinishesFirst_PlaysInSubmissionOrder() async throws {
        let synthesizer = ControlledSpeechSynthesizer()
        let audioPlayer = ControlledAudioPlayer()
        let queue = AgentSpeechQueue(
            synthesizer: synthesizer,
            audioPlayer: audioPlayer,
            systemSpeechPlayer: ControlledSystemSpeechPlayer())

        queue.enqueue(request("First."))
        queue.enqueue(request("Second."))
        try await waitUntil { await synthesizer.requestedTexts.count == 2 }
        await synthesizer.succeed("Second.")
        await Task.yield()
        #expect(audioPlayer.payloads.isEmpty)

        await synthesizer.succeed("First.")
        try await waitUntil { audioPlayer.payloads.count == 1 }
        #expect(audioPlayer.payloads == [Data("First.".utf8)])

        audioPlayer.finish()
        try await waitUntil { audioPlayer.payloads.count == 2 }
        #expect(audioPlayer.payloads == [
            Data("First.".utf8), Data("Second.".utf8),
        ])
        audioPlayer.finish()
        queue.stop()
    }

    @MainActor @Test
    func playback_WhenNextClipIsAlreadyReady_RemainsPlayingAcrossTheHandoff() async throws {
        let synthesizer = ControlledSpeechSynthesizer()
        let audioPlayer = ControlledAudioPlayer()
        let queue = AgentSpeechQueue(
            synthesizer: synthesizer,
            audioPlayer: audioPlayer,
            systemSpeechPlayer: ControlledSystemSpeechPlayer())
        var states: [AgentSpeechQueueState] = []
        queue.onStateChange = { states.append($0) }

        queue.enqueue(request("First."))
        queue.enqueue(request("Second."))
        try await waitUntil { await synthesizer.requestedTexts.count == 2 }
        await synthesizer.succeed("Second.")
        await synthesizer.succeed("First.")
        try await waitUntil { audioPlayer.payloads == [Data("First.".utf8)] }
        let statesBeforeHandoff = states

        audioPlayer.finish()
        try await waitUntil { audioPlayer.payloads.count == 2 }

        #expect(states == statesBeforeHandoff)
        #expect(states.last == .playing)
        audioPlayer.finish()
        queue.stop()
    }

    @MainActor @Test
    func playback_WhenNextClipIsStillSynthesizing_ReportsPreparingBetweenClips()
        async throws
    {
        let synthesizer = ControlledSpeechSynthesizer()
        let audioPlayer = ControlledAudioPlayer()
        let queue = AgentSpeechQueue(
            synthesizer: synthesizer,
            audioPlayer: audioPlayer,
            systemSpeechPlayer: ControlledSystemSpeechPlayer())
        var states: [AgentSpeechQueueState] = []
        queue.onStateChange = { states.append($0) }

        queue.enqueue(request("First."))
        queue.enqueue(request("Second."))
        try await waitUntil { await synthesizer.requestedTexts.count == 2 }
        await synthesizer.succeed("First.")
        try await waitUntil { states.last == .playing }

        audioPlayer.finish()

        #expect(states.last == .preparing)
        queue.stop()
        await synthesizer.succeed("Second.")
    }

    @MainActor @Test
    func playback_WhenCloudAudioCannotStart_FallsBackToSystemForThatSegment()
        async throws
    {
        let synthesizer = ControlledSpeechSynthesizer()
        let audioPlayer = ControlledAudioPlayer()
        audioPlayer.acceptsPlayback = false
        let systemPlayer = ControlledSystemSpeechPlayer()
        let queue = AgentSpeechQueue(
            synthesizer: synthesizer,
            audioPlayer: audioPlayer,
            systemSpeechPlayer: systemPlayer)

        queue.enqueue(request("Fallback."))
        try await waitUntil { await synthesizer.requestedTexts.count == 1 }
        await synthesizer.succeed("Fallback.")
        try await waitUntil { systemPlayer.texts == ["Fallback."] }

        #expect(systemPlayer.localeIDs == ["en-GB"])
        systemPlayer.finish()
        queue.stop()
    }

    @MainActor @Test
    func playback_WhenCloudSynthesisFails_FallsBackWithoutDiscardingLaterSegments()
        async throws
    {
        let synthesizer = ControlledSpeechSynthesizer()
        let audioPlayer = ControlledAudioPlayer()
        let systemPlayer = ControlledSystemSpeechPlayer()
        let queue = AgentSpeechQueue(
            synthesizer: synthesizer,
            audioPlayer: audioPlayer,
            systemSpeechPlayer: systemPlayer)

        queue.enqueue(request("First."))
        queue.enqueue(request("Second."))
        try await waitUntil { await synthesizer.requestedTexts.count == 2 }
        await synthesizer.fail("First.")
        await synthesizer.succeed("Second.")
        try await waitUntil { systemPlayer.texts == ["First."] }
        systemPlayer.finish()
        try await waitUntil { audioPlayer.payloads == [Data("Second.".utf8)] }

        audioPlayer.finish()
        queue.stop()
    }

    @MainActor @Test
    func stop_WhenSynthesisFinishesLate_DoesNotStartStalePlayback() async throws {
        let synthesizer = ControlledSpeechSynthesizer()
        let audioPlayer = ControlledAudioPlayer()
        let queue = AgentSpeechQueue(
            synthesizer: synthesizer,
            audioPlayer: audioPlayer,
            systemSpeechPlayer: ControlledSystemSpeechPlayer())
        var states: [AgentSpeechQueueState] = []
        queue.onStateChange = { states.append($0) }

        queue.enqueue(request("Stale."))
        try await waitUntil { await synthesizer.requestedTexts == ["Stale."] }
        queue.stop()
        await synthesizer.succeed("Stale.")
        await Task.yield()

        #expect(audioPlayer.payloads.isEmpty)
        #expect(states.last == .idle)
    }

    @MainActor @Test func stop_WhenPlaybackIsActive_StopsItAndRejectsLateCompletion()
        async throws
    {
        let synthesizer = ControlledSpeechSynthesizer()
        let audioPlayer = ControlledAudioPlayer()
        let queue = AgentSpeechQueue(
            synthesizer: synthesizer,
            audioPlayer: audioPlayer,
            systemSpeechPlayer: ControlledSystemSpeechPlayer())
        var states: [AgentSpeechQueueState] = []
        queue.onStateChange = { states.append($0) }
        queue.enqueue(request("Playing."))
        try await waitUntil { await synthesizer.requestedTexts == ["Playing."] }
        await synthesizer.succeed("Playing.")
        try await waitUntil { states.last == .playing }

        queue.stop()
        audioPlayer.finish()

        #expect(audioPlayer.stopCount == 1)
        #expect(states.last == .idle)
    }

    @MainActor
    private func request(_ text: String) -> AgentSpeechRequest {
        AgentSpeechRequest(
            text: text,
            localeID: "en-GB",
            configuration: AgentSpeechConfiguration(
                provider: .elevenLabs,
                elevenLabsAPIKey: "secret",
                elevenLabsVoiceID: "voice-1"))
    }

    @MainActor
    private func systemRequest(_ text: String) -> AgentSpeechRequest {
        AgentSpeechRequest(
            text: text,
            localeID: "en-GB",
            configuration: .systemDefault)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () async -> Bool) async throws
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TimeoutError()
    }

    private struct TimeoutError: Error {}
}

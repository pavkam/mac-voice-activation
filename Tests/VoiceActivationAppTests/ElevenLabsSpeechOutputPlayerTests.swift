// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationApp

private actor ElevenLabsSpeechSynthesizerSpy: ElevenLabsSpeechSynthesizing {
    struct Call: Equatable {
        let text: String
        let apiKey: String
        let voiceID: String
    }

    private(set) var calls: [Call] = []

    func audio(text: String, apiKey: String, voiceID: String) async throws -> Data {
        calls.append(Call(text: text, apiKey: apiKey, voiceID: voiceID))
        return Data(text.utf8)
    }
}

private actor GatedElevenLabsSpeechSynthesizer: ElevenLabsSpeechSynthesizing {
    private(set) var texts: [String] = []
    private var firstContinuation: CheckedContinuation<Data, Never>?

    func audio(text: String, apiKey: String, voiceID: String) async throws -> Data {
        texts.append(text)
        if texts.count == 1 {
            return await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return Data(text.utf8)
    }

    func releaseFirstRequest() {
        firstContinuation?.resume(returning: Data("first".utf8))
        firstContinuation = nil
    }
}

private struct DelayedElevenLabsFailure: Error {}

private actor CancellationIgnoringElevenLabsSpeechSynthesizer: ElevenLabsSpeechSynthesizing {
    private(set) var wasCalled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func audio(text: String, apiKey: String, voiceID: String) async throws -> Data {
        wasCalled = true
        await withCheckedContinuation { continuation = $0 }
        throw DelayedElevenLabsFailure()
    }

    func releaseWithFailure() {
        continuation?.resume()
        continuation = nil
    }
}

private actor FirstRequestFailingElevenLabsSpeechSynthesizer: ElevenLabsSpeechSynthesizing {
    private(set) var texts: [String] = []

    func audio(text: String, apiKey: String, voiceID: String) async throws -> Data {
        texts.append(text)
        if texts.count == 1 {
            throw DelayedElevenLabsFailure()
        }
        return Data(text.utf8)
    }
}

@MainActor
private final class AgentAudioDataPlayerSpy: AgentAudioDataPlaying {
    private(set) var payloads: [Data] = []
    private(set) var stopCount = 0
    var isPlaying = false
    var acceptsPlayback = true

    func play(_ data: Data) -> Bool {
        payloads.append(data)
        return acceptsPlayback
    }

    func stop() {
        stopCount += 1
        isPlaying = false
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ElevenLabsSpeechOutputPlayerTests {
    @MainActor @Test func speak_WhenChunksArrive_RequestsAndPlaysThemInOrder() async throws {
        let synthesizer = ElevenLabsSpeechSynthesizerSpy()
        let audioPlayer = AgentAudioDataPlayerSpy()
        let player = ElevenLabsSpeechOutputPlayer(
            synthesizer: synthesizer,
            audioPlayer: audioPlayer)
        var speakingStates: [Bool] = []
        await withCheckedContinuation { continuation in
            player.onSpeakingChange = { speaking in
                speakingStates.append(speaking)
                guard !speaking else { return }
                continuation.resume()
            }
            player.speak("First sentence.", apiKey: "secret", voiceID: "voice-1")
            player.speak("Second sentence.", apiKey: "secret", voiceID: "voice-1")
        }

        #expect(await synthesizer.calls == [
            .init(text: "First sentence.", apiKey: "secret", voiceID: "voice-1"),
            .init(text: "Second sentence.", apiKey: "secret", voiceID: "voice-1"),
        ])
        #expect(audioPlayer.payloads == [
            Data("First sentence.".utf8),
            Data("Second sentence.".utf8),
        ])
        #expect(speakingStates == [true, false])
    }

    @MainActor @Test func stop_WhenSynthesisIsPending_PreventsStaleAudioPlayback() async throws {
        let synthesizer = GatedElevenLabsSpeechSynthesizer()
        let audioPlayer = AgentAudioDataPlayerSpy()
        let player = ElevenLabsSpeechOutputPlayer(
            synthesizer: synthesizer,
            audioPlayer: audioPlayer)
        var speakingStates: [Bool] = []
        player.onSpeakingChange = { speakingStates.append($0) }

        player.speak("Do not play this.", apiKey: "secret", voiceID: "voice-1")
        await waitUntil { await synthesizer.texts.count == 1 }
        player.stop()
        await synthesizer.releaseFirstRequest()
        try await Task.sleep(for: .milliseconds(50))

        #expect(audioPlayer.payloads.isEmpty)
        #expect(audioPlayer.stopCount == 1)
        #expect(speakingStates == [true, false])
    }

    @MainActor @Test func stop_WhenCancelledRequestFailsLater_DoesNotInvokeFallback() async {
        let synthesizer = CancellationIgnoringElevenLabsSpeechSynthesizer()
        let audioPlayer = AgentAudioDataPlayerSpy()
        let player = ElevenLabsSpeechOutputPlayer(
            synthesizer: synthesizer,
            audioPlayer: audioPlayer)
        var failedTexts: [String] = []
        player.onFailure = { text, _ in failedTexts.append(text) }

        player.speak("Stale.", apiKey: "secret", voiceID: "voice-1")
        await waitUntil { await synthesizer.wasCalled }
        player.stop()
        await synthesizer.releaseWithFailure()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(failedTexts.isEmpty)
        #expect(audioPlayer.payloads.isEmpty)
    }

    @MainActor @Test func speak_WhenAudioCannotBeDecoded_ReportsTheChunkForFallback() async {
        let synthesizer = ElevenLabsSpeechSynthesizerSpy()
        let audioPlayer = AgentAudioDataPlayerSpy()
        audioPlayer.acceptsPlayback = false
        let player = ElevenLabsSpeechOutputPlayer(
            synthesizer: synthesizer,
            audioPlayer: audioPlayer)
        var failures: [(text: String, localeID: String)] = []
        await withCheckedContinuation { continuation in
            player.onFailure = {
                failures.append((text: $0, localeID: $1))
                continuation.resume()
            }
            player.speak(
                "Fallback please.",
                apiKey: "secret",
                voiceID: "voice-1",
                localeID: "en-GB")
        }

        #expect(failures.map(\.text) == ["Fallback please."])
        #expect(failures.map(\.localeID) == ["en-GB"])
    }

    @MainActor @Test func speak_WhenACloudRequestFails_CoalescesRemainingQueueIntoFallback()
        async
    {
        let synthesizer = FirstRequestFailingElevenLabsSpeechSynthesizer()
        let audioPlayer = AgentAudioDataPlayerSpy()
        let player = ElevenLabsSpeechOutputPlayer(
            synthesizer: synthesizer,
            audioPlayer: audioPlayer)
        var failedTexts: [String] = []
        await withCheckedContinuation { continuation in
            player.onFailure = { text, _ in
                failedTexts.append(text)
                continuation.resume()
            }
            player.speak("First.", apiKey: "secret", voiceID: "voice-1")
            player.speak("Second.", apiKey: "secret", voiceID: "voice-1")
        }

        #expect(failedTexts == ["First. Second."])
        #expect(await synthesizer.texts == ["First."])
        #expect(audioPlayer.payloads.isEmpty)
    }

    @MainActor @Test func speak_WhenProducerOutrunsPlayback_BoundsAndCoalescesPendingChunks()
        async
    {
        let synthesizer = GatedElevenLabsSpeechSynthesizer()
        let audioPlayer = AgentAudioDataPlayerSpy()
        let player = ElevenLabsSpeechOutputPlayer(
            synthesizer: synthesizer,
            audioPlayer: audioPlayer)
        var speakingStates: [Bool] = []
        player.onSpeakingChange = { speakingStates.append($0) }

        player.speak("Chunk 0.", apiKey: "secret", voiceID: "voice-1")
        await waitUntil { await synthesizer.texts.count == 1 }
        for index in 1..<100 {
            player.speak("Chunk \(index).", apiKey: "secret", voiceID: "voice-1")
        }
        await synthesizer.releaseFirstRequest()
        await waitUntil { speakingStates.last == false }

        let requestedTexts = await synthesizer.texts
        #expect(requestedTexts.count <= 65)
        #expect(requestedTexts.last?.contains("Chunk 99.") == true)
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

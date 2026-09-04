// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationApp

private actor ElevenLabsVoicePreviewSynthesizerSpy: ElevenLabsSpeechSynthesizing {
    private(set) var requests: [(text: String, apiKey: String, voiceID: String)] = []

    func audio(text: String, apiKey: String, voiceID: String) async throws -> Data {
        requests.append((text, apiKey, voiceID))
        return Data([1, 2, 3])
    }
}

private actor GatedElevenLabsVoicePreviewSynthesizer: ElevenLabsSpeechSynthesizing {
    private var continuation: CheckedContinuation<Data, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func audio(text: String, apiKey: String, voiceID: String) async throws -> Data {
        let waiters = waiters
        self.waiters = []
        for waiter in waiters {
            waiter.resume()
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilRequested() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        continuation?.resume(returning: Data([1, 2, 3]))
        continuation = nil
    }
}

@MainActor
private final class ElevenLabsVoicePreviewAudioPlayerSpy: AgentAudioDataPlaying {
    private(set) var playedData: [Data] = []
    private(set) var stopCount = 0
    var acceptsAudio = true

    func play(
        _ data: Data,
        completion: @escaping @MainActor (Bool) -> Void) -> Bool
    {
        playedData.append(data)
        if acceptsAudio {
            completion(true)
        }
        return acceptsAudio
    }

    func stop() {
        stopCount += 1
    }
}

struct ElevenLabsVoicePreviewPlayerTests {
    @MainActor @Test func play_WhenSynthesisSucceeds_PlaysShortSampleWithoutSystemAudio() async throws {
        let synthesizer = ElevenLabsVoicePreviewSynthesizerSpy()
        let audioPlayer = ElevenLabsVoicePreviewAudioPlayerSpy()
        let preview = ElevenLabsVoicePreviewPlayer(
            synthesizer: synthesizer,
            audioPlayer: audioPlayer)

        try await preview.play(apiKey: "secret", voiceID: "voice-1")

        let requests = await synthesizer.requests
        #expect(requests.count == 1)
        #expect(requests[0].apiKey == "secret")
        #expect(requests[0].voiceID == "voice-1")
        #expect(requests[0].text.contains("Voice Activation"))
        #expect(audioPlayer.playedData == [Data([1, 2, 3])])
    }

    @MainActor @Test func play_WhenAudioCannotStart_ThrowsPlaybackError() async throws {
        let audioPlayer = ElevenLabsVoicePreviewAudioPlayerSpy()
        audioPlayer.acceptsAudio = false
        let preview = ElevenLabsVoicePreviewPlayer(
            synthesizer: ElevenLabsVoicePreviewSynthesizerSpy(),
            audioPlayer: audioPlayer)

        await #expect(throws: ElevenLabsVoicePreviewError.playbackFailed) {
            try await preview.play(apiKey: "secret", voiceID: "voice-1")
        }
    }

    @MainActor @Test func stop_WhenSynthesisIsPending_PreventsStalePreviewPlayback() async {
        let synthesizer = GatedElevenLabsVoicePreviewSynthesizer()
        let audioPlayer = ElevenLabsVoicePreviewAudioPlayerSpy()
        let preview = ElevenLabsVoicePreviewPlayer(
            synthesizer: synthesizer,
            audioPlayer: audioPlayer)
        let task = Task {
            try await preview.play(apiKey: "secret", voiceID: "voice-1")
        }
        await synthesizer.waitUntilRequested()

        preview.stop()
        await synthesizer.release()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(audioPlayer.playedData.isEmpty)
    }
}

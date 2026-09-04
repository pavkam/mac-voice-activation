// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

@MainActor
protocol ElevenLabsVoicePreviewing: AnyObject {
    func play(apiKey: String, voiceID: String) async throws
    func stop()
}

enum ElevenLabsVoicePreviewError: Error, Equatable, LocalizedError {
    case playbackFailed

    var errorDescription: String? {
        "The ElevenLabs voice preview could not be played."
    }
}

@MainActor
final class ElevenLabsVoicePreviewPlayer: ElevenLabsVoicePreviewing {
    private static let sample = "Hello from Voice Activation. This is how I will sound."

    private let synthesizer: any ElevenLabsSpeechSynthesizing
    private let audioPlayer: any AgentAudioDataPlaying
    private var generation = 0
    private var playbackContinuation: CheckedContinuation<Void, any Error>?

    init(
        synthesizer: any ElevenLabsSpeechSynthesizing = ElevenLabsSpeechClient(),
        audioPlayer: any AgentAudioDataPlaying = SystemAgentAudioDataPlayer())
    {
        self.synthesizer = synthesizer
        self.audioPlayer = audioPlayer
    }

    func play(apiKey: String, voiceID: String) async throws {
        generation &+= 1
        let activeGeneration = generation
        audioPlayer.stop()
        let data = try await synthesizer.audio(
            text: Self.sample,
            apiKey: apiKey,
            voiceID: voiceID)
        try Task.checkCancellation()
        guard generation == activeGeneration else {
            throw CancellationError()
        }
        try await withCheckedThrowingContinuation { continuation in
            playbackContinuation = continuation
            guard audioPlayer.play(data, completion: { [weak self] _ in
                self?.finishPlayback(generation: activeGeneration)
            }) else {
                playbackContinuation = nil
                continuation.resume(throwing: ElevenLabsVoicePreviewError.playbackFailed)
                return
            }
        }
    }

    func stop() {
        generation &+= 1
        audioPlayer.stop()
        playbackContinuation?.resume(throwing: CancellationError())
        playbackContinuation = nil
    }

    private func finishPlayback(generation activeGeneration: Int) {
        guard generation == activeGeneration else { return }
        playbackContinuation?.resume()
        playbackContinuation = nil
    }
}

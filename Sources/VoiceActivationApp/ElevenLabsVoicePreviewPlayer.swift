// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import VoiceActivationCore

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
    private let diagnostics: any VoiceActivationDiagnosticRecording
    private var generation = 0
    private var playbackContinuation: CheckedContinuation<Void, any Error>?

    init(
        synthesizer: any ElevenLabsSpeechSynthesizing = ElevenLabsSpeechClient(),
        audioPlayer: any AgentAudioDataPlaying = SystemAgentAudioDataPlayer(),
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.synthesizer = synthesizer
        self.audioPlayer = audioPlayer
        self.diagnostics = diagnostics
    }

    func play(apiKey: String, voiceID: String) async throws {
        generation &+= 1
        let activeGeneration = generation
        diagnostics.record(
            category: .audio,
            event: "voice_preview.started",
            fields: ["generation": String(activeGeneration)])
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
            guard
                audioPlayer.play(
                    data,
                    completion: { [weak self] _ in
                        self?.finishPlayback(generation: activeGeneration)
                    })
            else {
                diagnostics.record(
                    category: .audio,
                    event: "voice_preview.playback_failed",
                    level: .error,
                    fields: [
                        "generation": String(activeGeneration),
                        "audio_byte_count": String(data.count),
                    ])
                playbackContinuation = nil
                continuation.resume(throwing: ElevenLabsVoicePreviewError.playbackFailed)
                return
            }
        }
    }

    func stop() {
        let stoppedGeneration = generation
        generation &+= 1
        audioPlayer.stop()
        playbackContinuation?.resume(throwing: CancellationError())
        playbackContinuation = nil
        diagnostics.record(
            category: .audio,
            event: "voice_preview.stopped",
            fields: [
                "previous_generation": String(stoppedGeneration),
                "generation": String(generation),
            ])
    }

    private func finishPlayback(generation activeGeneration: Int) {
        guard generation == activeGeneration else { return }
        playbackContinuation?.resume()
        playbackContinuation = nil
        diagnostics.record(
            category: .audio,
            event: "voice_preview.finished",
            fields: ["generation": String(activeGeneration)])
    }
}

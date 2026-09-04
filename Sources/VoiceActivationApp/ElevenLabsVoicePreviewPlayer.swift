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
        guard audioPlayer.play(data) else {
            throw ElevenLabsVoicePreviewError.playbackFailed
        }

        do {
            while audioPlayer.isPlaying {
                try await Task.sleep(for: .milliseconds(50))
                guard generation == activeGeneration else {
                    throw CancellationError()
                }
            }
        } catch {
            audioPlayer.stop()
            throw error
        }
    }

    func stop() {
        generation &+= 1
        audioPlayer.stop()
    }
}

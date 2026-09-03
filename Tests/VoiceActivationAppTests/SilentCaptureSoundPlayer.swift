@testable import VoiceActivationApp

@MainActor
final class SilentCaptureSoundPlayer: CaptureSoundPlaying {
    func play(_ event: CaptureSoundEvent) {}
}

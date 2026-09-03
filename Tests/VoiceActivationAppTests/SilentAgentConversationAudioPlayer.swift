@testable import VoiceActivationApp

@MainActor
final class SilentAgentConversationAudioPlayer: AgentConversationAudioPlaying {
    var onSpeakingChange: ((Bool) -> Void)?

    func setWorking(_ working: Bool) {}
    func speak(_ text: String, localeID: String) {}
    func stopSpeaking() {}
    func stopAll() {}
}

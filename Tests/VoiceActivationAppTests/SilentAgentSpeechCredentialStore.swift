@testable import VoiceActivationApp

@MainActor
final class SilentAgentSpeechCredentialStore: AgentSpeechCredentialStoring {
    private var apiKey: String?

    init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    func loadElevenLabsAPIKey() throws -> String? {
        apiKey
    }

    func saveElevenLabsAPIKey(_ apiKey: String?) throws {
        self.apiKey = apiKey
    }
}

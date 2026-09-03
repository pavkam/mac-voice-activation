import VoiceActivationCore

@MainActor
final class AgentSpeechSettingsState {
    private(set) var configuration: AgentSpeechConfiguration

    init(
        provider: AgentSpeechProvider,
        elevenLabsAPIKey: String,
        elevenLabsVoiceID: String)
    {
        configuration = AgentSpeechConfiguration(
            provider: provider,
            elevenLabsAPIKey: elevenLabsAPIKey,
            elevenLabsVoiceID: elevenLabsVoiceID)
    }

    func update(
        provider: AgentSpeechProvider,
        elevenLabsAPIKey: String,
        elevenLabsVoiceID: String)
    {
        configuration = AgentSpeechConfiguration(
            provider: provider,
            elevenLabsAPIKey: elevenLabsAPIKey,
            elevenLabsVoiceID: elevenLabsVoiceID)
    }
}

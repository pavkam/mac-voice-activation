import VoiceActivationCore

struct MenuStatusPresentation: Equatable {
    let title: String
    let detail: String
    let symbolName: String
    let isError: Bool

    static func make(
        state: ActivationState,
        enabledProfileCount: Int,
        isListeningEnabled: Bool,
        agentPhase: AgentRunPhase? = nil) -> MenuStatusPresentation
    {
        if state == .executing, let agentPhase, !agentPhase.isTerminal {
            return agentConversationPresentation(phase: agentPhase)
        }

        if state == .disabled, isListeningEnabled {
            guard enabledProfileCount > 0 else {
                return MenuStatusPresentation(
                    title: "No active wake phrases",
                    detail: "Enable a profile to start listening",
                    symbolName: "waveform.slash",
                    isError: false)
            }
            return MenuStatusPresentation(
                title: "Starting",
                detail: "Preparing wake phrase listening",
                symbolName: "waveform",
                isError: false)
        }

        return switch state {
        case .disabled:
            MenuStatusPresentation(
                title: "Paused",
                detail: "Wake phrase listening is off",
                symbolName: "pause.fill",
                isError: false)
        case .listening:
            MenuStatusPresentation(
                title: "Ready",
                detail: listeningDetail(enabledProfileCount: enabledProfileCount),
                symbolName: "waveform",
                isError: false)
        case .capturing:
            MenuStatusPresentation(
                title: "Listening now",
                detail: "Speak your command",
                symbolName: "waveform.badge.mic",
                isError: false)
        case .executing:
            MenuStatusPresentation(
                title: "Running command",
                detail: "Your request is on its way",
                symbolName: "sparkles",
                isError: false)
        case let .failed(message):
            MenuStatusPresentation(
                title: "Needs attention",
                detail: message,
                symbolName: "exclamationmark.triangle.fill",
                isError: true)
        }
    }

    private static func listeningDetail(enabledProfileCount: Int) -> String {
        let noun = enabledProfileCount == 1 ? "wake phrase" : "wake phrases"
        return "Listening for \(enabledProfileCount) \(noun)"
    }

    private static func agentConversationPresentation(
        phase: AgentRunPhase) -> MenuStatusPresentation
    {
        switch phase {
        case .listening:
            MenuStatusPresentation(
                title: "In conversation",
                detail: "Listening for a follow-up",
                symbolName: "waveform.badge.mic",
                isError: false)
        case .running:
            MenuStatusPresentation(
                title: "Agent working",
                detail: "You can keep speaking",
                symbolName: "sparkles",
                isError: false)
        case .cancelling:
            MenuStatusPresentation(
                title: "Stopping turn",
                detail: "Conversation stays open",
                symbolName: "clock.arrow.circlepath",
                isError: false)
        case .completed, .failed:
            MenuStatusPresentation(
                title: "Running command",
                detail: "Your request is on its way",
                symbolName: "sparkles",
                isError: false)
        }
    }
}

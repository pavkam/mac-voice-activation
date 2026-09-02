import VoiceActivationCore

struct MenuStatusPresentation: Equatable {
    let title: String
    let detail: String
    let symbolName: String
    let isError: Bool

    static func make(
        state: ActivationState,
        enabledProfileCount: Int) -> MenuStatusPresentation
    {
        switch state {
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
}

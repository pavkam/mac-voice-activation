import Foundation

public enum WakeProfileAccent: String, CaseIterable, Codable, Equatable, Sendable {
    case cyan
    case blue
    case purple
    case pink
    case orange
    case green
}

public struct WakeProfile: Codable, Equatable, Identifiable, Sendable {
    public enum ValidationError: Error, Equatable, LocalizedError {
        case wakePhraseRequired
        case missingTranscriptPlaceholder

        public var errorDescription: String? {
            switch self {
            case .wakePhraseRequired:
                "Every wake profile needs a wake phrase."
            case .missingTranscriptPlaceholder:
                "Every wake profile URL must contain {text} or {urlText}."
            }
        }
    }

    public static let defaultValue = try! WakeProfile(
        id: UUID(uuidString: "50443ED5-4EBC-40CA-8434-AFBCA06BEE5A")!,
        wakePhrase: "computer",
        executablePath: "/usr/bin/open",
        argumentTemplates: ["https://www.google.com/search?q={urlText}"],
        accent: .blue)

    public let id: UUID
    public var wakePhrase: String
    public var executablePath: String
    public var argumentTemplates: [String]
    public var accent: WakeProfileAccent

    public init(
        id: UUID = UUID(),
        wakePhrase: String,
        urlTemplate: String,
        accent: WakeProfileAccent) throws
    {
        try self.init(
            id: id,
            wakePhrase: wakePhrase,
            executablePath: "/usr/bin/open",
            argumentTemplates: [urlTemplate],
            accent: accent)
    }

    public init(
        id: UUID = UUID(),
        wakePhrase: String,
        executablePath: String,
        argumentTemplates: [String],
        accent: WakeProfileAccent) throws
    {
        let normalizedPhrase = wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPhrase.isEmpty else {
            throw ValidationError.wakePhraseRequired
        }
        guard argumentTemplates.contains(where: {
            $0.contains("{text}") || $0.contains("{urlText}")
        }) else {
            throw ValidationError.missingTranscriptPlaceholder
        }
        _ = try CommandTemplate(
            executablePath: executablePath,
            argumentTemplates: argumentTemplates)

        self.id = id
        self.wakePhrase = normalizedPhrase
        self.executablePath = executablePath
        self.argumentTemplates = argumentTemplates
        self.accent = accent
    }

    public var commandTemplate: CommandTemplate {
        get throws {
            try CommandTemplate(
                executablePath: executablePath,
                argumentTemplates: argumentTemplates)
        }
    }
}

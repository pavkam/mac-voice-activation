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
    private enum CodingKeys: String, CodingKey {
        case id
        case wakePhrase
        case action
        case executablePath
        case argumentTemplates
        case accent
        case isEnabled
        case pushToTalkHotKey
    }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case wakePhraseRequired
        case missingTranscriptPlaceholder
        case actionIsNotCommand

        public var errorDescription: String? {
            switch self {
            case .wakePhraseRequired:
                "Every wake profile needs a wake phrase."
            case .missingTranscriptPlaceholder:
                "Every wake profile URL must contain {text} or {urlText}."
            case .actionIsNotCommand:
                "This wake profile does not run a direct command."
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
    public var action: WakeProfileAction
    public var accent: WakeProfileAccent
    public var isEnabled: Bool
    public var pushToTalkHotKey: PushToTalkHotKey?

    public var executablePath: String {
        guard case let .command(template) = action else { return "" }
        return template.executablePath
    }

    public var argumentTemplates: [String] {
        guard case let .command(template) = action else { return [] }
        return template.argumentTemplates
    }

    public init(
        id: UUID = UUID(),
        wakePhrase: String,
        action: WakeProfileAction,
        accent: WakeProfileAccent,
        isEnabled: Bool = true,
        pushToTalkHotKey: PushToTalkHotKey? = nil) throws
    {
        let normalizedPhrase = wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPhrase.isEmpty else {
            throw ValidationError.wakePhraseRequired
        }

        self.id = id
        self.wakePhrase = normalizedPhrase
        self.action = action
        self.accent = accent
        self.isEnabled = isEnabled
        self.pushToTalkHotKey = pushToTalkHotKey
    }

    public init(
        id: UUID = UUID(),
        wakePhrase: String,
        urlTemplate: String,
        accent: WakeProfileAccent,
        isEnabled: Bool = true,
        pushToTalkHotKey: PushToTalkHotKey? = nil) throws
    {
        try self.init(
            id: id,
            wakePhrase: wakePhrase,
            executablePath: "/usr/bin/open",
            argumentTemplates: [urlTemplate],
            accent: accent,
            isEnabled: isEnabled,
            pushToTalkHotKey: pushToTalkHotKey)
    }

    public init(
        id: UUID = UUID(),
        wakePhrase: String,
        executablePath: String,
        argumentTemplates: [String],
        accent: WakeProfileAccent,
        isEnabled: Bool = true,
        pushToTalkHotKey: PushToTalkHotKey? = nil) throws
    {
        guard argumentTemplates.contains(where: {
            $0.contains("{text}") || $0.contains("{urlText}")
        }) else {
            throw ValidationError.missingTranscriptPlaceholder
        }
        let commandTemplate = try CommandTemplate(
            executablePath: executablePath,
            argumentTemplates: argumentTemplates)
        try self.init(
            id: id,
            wakePhrase: wakePhrase,
            action: .command(commandTemplate),
            accent: accent,
            isEnabled: isEnabled,
            pushToTalkHotKey: pushToTalkHotKey)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let action: WakeProfileAction
        if container.contains(.action) {
            action = try container.decode(WakeProfileAction.self, forKey: .action)
        } else {
            action = .command(try CommandTemplate(
                executablePath: container.decode(String.self, forKey: .executablePath),
                argumentTemplates: container.decode([String].self, forKey: .argumentTemplates)))
        }
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            wakePhrase: container.decode(String.self, forKey: .wakePhrase),
            action: action,
            accent: container.decode(WakeProfileAccent.self, forKey: .accent),
            isEnabled: container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            pushToTalkHotKey: container.decodeIfPresent(
                PushToTalkHotKey.self,
                forKey: .pushToTalkHotKey))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(wakePhrase, forKey: .wakePhrase)
        try container.encode(action, forKey: .action)
        try container.encode(accent, forKey: .accent)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(pushToTalkHotKey, forKey: .pushToTalkHotKey)
    }

    public var commandTemplate: CommandTemplate {
        get throws {
            guard case let .command(template) = action else {
                throw ValidationError.actionIsNotCommand
            }
            return template
        }
    }
}

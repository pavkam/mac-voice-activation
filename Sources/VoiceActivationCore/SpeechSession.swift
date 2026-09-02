import Foundation

public enum SpeechSessionMode: Equatable, Sendable {
    case passiveWake
    case commandCapture
    case pushToTalk
}

public struct SpeechUpdate: Equatable, Sendable {
    public let transcript: String
    public let isFinal: Bool
    public let errorDescription: String?

    public init(transcript: String, isFinal: Bool, errorDescription: String?) {
        self.transcript = transcript
        self.isFinal = isFinal
        self.errorDescription = errorDescription
    }
}

@MainActor
public protocol SpeechSessionProtocol: AnyObject {
    func start(
        mode: SpeechSessionMode,
        localeID: String,
        contextualStrings: [String],
        onUpdate: @escaping (SpeechUpdate) -> Void,
        onInterruption: @escaping () -> Void) throws

    func stop()
}

public struct ActivationConfiguration: Equatable, Sendable {
    public let profiles: [WakeProfile]
    public let localeID: String
    public let pushToTalkCommandTemplate: CommandTemplate

    public init(
        profiles: [WakeProfile],
        localeID: String,
        pushToTalkCommandTemplate: CommandTemplate? = nil)
    {
        self.profiles = profiles.isEmpty ? [.defaultValue] : profiles
        self.localeID = localeID
        self.pushToTalkCommandTemplate = pushToTalkCommandTemplate
            ?? (try! self.profiles[0].commandTemplate)
    }

    public init(wakePhrase: String, localeID: String, commandTemplate: CommandTemplate) {
        let normalizedPhrase = wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles = [try! WakeProfile(
            id: WakeProfile.defaultValue.id,
            wakePhrase: normalizedPhrase.isEmpty ? "computer" : normalizedPhrase,
            executablePath: commandTemplate.executablePath,
            argumentTemplates: commandTemplate.argumentTemplates,
            accent: .blue)]
        self.localeID = localeID
        pushToTalkCommandTemplate = commandTemplate
    }
}

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
        onUpdate: @escaping (SpeechUpdate) -> Void,
        onInterruption: @escaping () -> Void) throws

    func stop()
}

public struct ActivationConfiguration: Equatable, Sendable {
    public let wakePhrase: String
    public let localeID: String
    public let commandTemplate: CommandTemplate

    public init(wakePhrase: String, localeID: String, commandTemplate: CommandTemplate) {
        self.wakePhrase = wakePhrase
        self.localeID = localeID
        self.commandTemplate = commandTemplate
    }
}

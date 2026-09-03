import Foundation

private struct PhysicalHotKeyIdentity: Hashable {
    let keyCode: UInt32
    let modifiers: HotKeyModifiers

    init(_ hotKey: PushToTalkHotKey) {
        keyCode = hotKey.keyCode
        modifiers = hotKey.modifiers
    }
}

public enum WakeProfileCollectionValidationError: Error, Equatable, LocalizedError {
    case profileRequired
    case duplicateWakePhrase
    case duplicatePushToTalkHotKey

    public var errorDescription: String? {
        switch self {
        case .profileRequired:
            "Add at least one wake profile."
        case .duplicateWakePhrase:
            "Wake phrases must be unique."
        case .duplicatePushToTalkHotKey:
            "Push-to-talk shortcuts must be unique."
        }
    }
}

public enum WakeProfileCollectionValidator {
    public static func validate(_ profiles: [WakeProfile]) throws {
        guard !profiles.isEmpty else {
            throw WakeProfileCollectionValidationError.profileRequired
        }

        let phrases = profiles.map { WakePhraseMatcher.canonicalWakePhrase($0.wakePhrase) }
        guard Set(phrases).count == phrases.count else {
            throw WakeProfileCollectionValidationError.duplicateWakePhrase
        }

        let hotKeys = profiles.compactMap(\.pushToTalkHotKey).map(PhysicalHotKeyIdentity.init)
        guard Set(hotKeys).count == hotKeys.count else {
            throw WakeProfileCollectionValidationError.duplicatePushToTalkHotKey
        }
    }
}

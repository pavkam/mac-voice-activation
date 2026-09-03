import Foundation

public enum WakePhraseMatcher {
    public struct Match: Equatable, Sendable {
        public let profile: WakeProfile
        public let command: String
    }

    private static let leadingAndTrailing = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)

    static func normalizedWakePhrase(_ phrase: String) -> String {
        let spokenScalars = phrase.unicodeScalars.filter {
            $0.properties.isWhitespace || !CharacterSet.controlCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(spokenScalars))
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    static func canonicalWakePhrase(_ phrase: String) -> String {
        normalizedWakePhrase(phrase)
            .trimmingCharacters(in: leadingAndTrailing)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX"))
    }

    static func containsSpokenCharacter(_ phrase: String) -> Bool {
        phrase.contains { $0.isLetter || $0.isNumber }
    }

    public static func command(in transcript: String, wakePhrase: String) -> String? {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = normalizedWakePhrase(wakePhrase)
            .trimmingCharacters(in: leadingAndTrailing)
        guard !spoken.isEmpty, !phrase.isEmpty else { return nil }

        let options: String.CompareOptions = [
            .anchored,
            .caseInsensitive,
            .diacriticInsensitive,
            .widthInsensitive,
        ]
        guard let range = spoken.range(of: phrase, options: options) else { return nil }

        if range.upperBound < spoken.endIndex {
            let next = spoken[range.upperBound]
            guard !next.isLetter, !next.isNumber else { return nil }
        }

        return String(spoken[range.upperBound...])
            .trimmingCharacters(in: leadingAndTrailing)
    }

    public static func match(in transcript: String, profiles: [WakeProfile]) -> Match? {
        profiles
            .filter(\.isEnabled)
            .sorted { $0.wakePhrase.count > $1.wakePhrase.count }
            .lazy
            .compactMap { profile in
                command(in: transcript, wakePhrase: profile.wakePhrase).map {
                    Match(profile: profile, command: $0)
                }
            }
            .first
    }
}

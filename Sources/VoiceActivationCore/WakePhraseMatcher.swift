import Foundation

public enum WakePhraseMatcher {
    private static let leadingAndTrailing = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)

    public static func command(in transcript: String, wakePhrase: String) -> String? {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = wakePhrase.trimmingCharacters(in: leadingAndTrailing)
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
}

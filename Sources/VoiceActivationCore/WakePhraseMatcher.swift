// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// Normalizes wake phrases and matches them only at the beginning of recognized speech.
public enum WakePhraseMatcher {
    /// A selected profile and the transcript remaining after its wake phrase.
    public struct Match: Equatable, Sendable {
        /// The longest enabled profile whose phrase matched.
        public let profile: WakeProfile
        /// The trimmed text that followed the matched phrase.
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

    /// Removes a leading wake phrase while respecting word boundaries.
    ///
    /// - Parameters:
    ///   - transcript: The complete or partial recognized utterance.
    ///   - wakePhrase: The configured phrase expected at the utterance start.
    /// - Returns: The remaining command, or `nil` when the phrase does not match.
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

    /// Selects the longest matching enabled profile.
    ///
    /// - Parameters:
    ///   - transcript: The complete or partial recognized utterance.
    ///   - profiles: The candidate wake profiles.
    /// - Returns: The selected profile and remaining command, or `nil` when no phrase matches.
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

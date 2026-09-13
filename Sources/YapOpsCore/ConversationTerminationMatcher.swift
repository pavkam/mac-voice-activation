// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// Matches a final spoken utterance against the configured terminal phrases
/// that end a live agent conversation.
///
/// Distinct from `CaptureCancellationMatcher`, which only ever matches a
/// single cancellation word (and tolerates it doubling in a partial
/// transcript) for raw command capture, where there is no panel to close.
/// This matcher supports multi-word phrases like "thank you" and only ever
/// runs against a final transcript: a partial utterance saying "thanks" on
/// its way to "thanks for checking" must not end the conversation before the
/// rest of the sentence lands.
enum ConversationTerminationMatcher {
    /// Whether the entire utterance is exactly one configured phrase, ignoring
    /// case, diacritics, width and punctuation.
    ///
    /// - Parameters:
    ///   - transcript: The final recognized utterance.
    ///   - phrases: The configured terminal phrases. An empty or blank phrase
    ///     is ignored rather than matching every empty transcript.
    static func matches(_ transcript: String, phrases: [String]) -> Bool {
        let transcriptWords = normalizedWords(in: transcript)
        guard !transcriptWords.isEmpty else { return false }
        return phrases.contains { phrase in
            let phraseWords = normalizedWords(in: phrase)
            return !phraseWords.isEmpty && phraseWords == transcriptWords
        }
    }

    private static func normalizedWords(in text: String) -> [String] {
        text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map {
                String($0).folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US_POSIX"))
            }
    }
}

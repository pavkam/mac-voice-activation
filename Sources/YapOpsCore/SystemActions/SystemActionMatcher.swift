// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// Resolves the text spoken after a wake phrase to one bound system action.
///
/// Resolution is decided against partial recognition as well as final results,
/// so a profile can act the moment a term can no longer become a longer one.
/// Saying "mac lock" runs immediately; saying "mac next" waits, because "next
/// track" is still reachable.
public enum SystemActionMatcher {
    /// The action selected by a spoken term.
    public struct Match: Equatable, Sendable {
        /// The macOS operation to perform.
        public let action: SystemAction
        /// The binding that claimed the term.
        public let bindingID: UUID
        /// The configured term as the user wrote it.
        public let phrase: String
    }

    /// What the currently recognized text allows a profile to do.
    public enum Resolution: Equatable, Sendable {
        /// The text names no term and cannot grow into one.
        case unmatched
        /// The text could still become a term, or a longer term, with more speech.
        case pending
        /// The text names exactly one term and no longer term extends it.
        case matched(Match)
    }

    /// Resolves recognized text against a profile's bindings.
    ///
    /// - Parameters:
    ///   - spoken: The transcript remaining after the wake phrase.
    ///   - set: The profile's action bindings.
    ///   - isComplete: Whether the recognizer considers the utterance final.
    /// - Returns: The resolution for this recognition state.
    public static func resolve(
        _ spoken: String,
        in set: SystemActionSet,
        isComplete: Bool
    ) -> Resolution {
        let canonical = WakePhraseMatcher.canonicalWakePhrase(spoken)
        guard !canonical.isEmpty else {
            return isComplete ? .unmatched : .pending
        }

        var exact: Match?
        var hasLongerCandidate = false
        for binding in set.bindings {
            for (index, phrase) in binding.canonicalPhrases.enumerated() {
                if phrase == canonical {
                    exact = Match(
                        action: binding.action,
                        bindingID: binding.id,
                        phrase: binding.phrases[index])
                } else if phrase.hasPrefix(canonical) {
                    hasLongerCandidate = true
                }
            }
        }

        if let exact {
            // A final utterance settles the term even when a longer one exists,
            // because no further speech is coming to extend it.
            return hasLongerCandidate && !isComplete ? .pending : .matched(exact)
        }
        if hasLongerCandidate, !isComplete {
            return .pending
        }
        return .unmatched
    }

    /// Resolves a completed utterance to its bound action.
    ///
    /// - Parameters:
    ///   - spoken: The transcript remaining after the wake phrase.
    ///   - set: The profile's action bindings.
    /// - Returns: The matched action, or `nil` when the term is not bound.
    public static func match(_ spoken: String, in set: SystemActionSet) -> Match? {
        guard case let .matched(match) = resolve(spoken, in: set, isComplete: true) else {
            return nil
        }
        return match
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// The spoken terms that invoke one system action.
public struct SystemActionBinding: Codable, Equatable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case action
        case phrases
    }

    /// Reasons a binding cannot be used.
    public enum ValidationError: Error, Equatable, LocalizedError {
        /// Every phrase was empty once normalized.
        case phraseRequired

        /// A user-presentable explanation of the invalid binding.
        public var errorDescription: String? {
            switch self {
            case .phraseRequired:
                "Every system action needs at least one spoken term."
            }
        }
    }

    /// The stable identity used by the editor and by diagnostics.
    public let id: UUID
    /// The macOS operation invoked when one of the terms is recognized.
    public var action: SystemAction
    /// The normalized spoken terms, in the order the user arranged them.
    public private(set) var phrases: [String]

    /// Creates a binding from user-entered terms.
    ///
    /// Terms are normalized the same way wake phrases are, then de-duplicated
    /// while preserving order. Empty terms are discarded rather than rejected,
    /// so a trailing blank row in the editor does not fail the whole profile.
    ///
    /// - Parameters:
    ///   - id: The stable binding identity.
    ///   - action: The macOS operation to invoke.
    ///   - phrases: The spoken terms that select the action.
    /// - Throws: ``ValidationError/phraseRequired`` when no term survives normalization.
    public init(id: UUID = UUID(), action: SystemAction, phrases: [String]) throws {
        var seen: Set<String> = []
        var normalized: [String] = []
        for phrase in phrases {
            let cleaned = WakePhraseMatcher.normalizedWakePhrase(phrase)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard WakePhraseMatcher.containsSpokenCharacter(cleaned) else { continue }
            let canonical = WakePhraseMatcher.canonicalWakePhrase(cleaned)
            guard seen.insert(canonical).inserted else { continue }
            normalized.append(cleaned)
        }
        guard !normalized.isEmpty else { throw ValidationError.phraseRequired }

        self.id = id
        self.action = action
        self.phrases = normalized
    }

    /// Creates a binding using the action's own suggested terms.
    ///
    /// - Parameters:
    ///   - action: The macOS operation to invoke.
    ///   - id: The stable binding identity.
    public init(suggestedFor action: SystemAction, id: UUID = UUID()) {
        // Every action ships at least one non-empty suggestion, so this cannot
        // fail; the catalog is covered by `everyAction_HasUsableSuggestedPhrases`.
        self = try! SystemActionBinding(
            id: id,
            action: action,
            phrases: action.suggestedPhrases)
    }

    /// Replaces the spoken terms.
    ///
    /// - Parameter phrases: The new user-entered terms.
    /// - Throws: ``ValidationError/phraseRequired`` when no term survives normalization.
    public mutating func setPhrases(_ phrases: [String]) throws {
        self = try SystemActionBinding(id: id, action: action, phrases: phrases)
    }

    /// The comparison forms of this binding's terms.
    public var canonicalPhrases: [String] {
        phrases.map(WakePhraseMatcher.canonicalWakePhrase)
    }

    /// Decodes a binding, rejecting one whose action this build does not know.
    ///
    /// - Parameter decoder: The persisted binding decoder.
    /// - Throws: A decoding or validation error.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawAction = try container.decode(String.self, forKey: .action)
        guard let action = SystemAction(rawValue: rawAction) else {
            throw DecodingError.dataCorruptedError(
                forKey: .action,
                in: container,
                debugDescription: "Unsupported system action \(rawAction)")
        }
        try self.init(
            id: container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            action: action,
            phrases: container.decode([String].self, forKey: .phrases))
    }

    /// Encodes the binding.
    ///
    /// - Parameter encoder: The destination encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(action.rawValue, forKey: .action)
        try container.encode(phrases, forKey: .phrases)
    }
}

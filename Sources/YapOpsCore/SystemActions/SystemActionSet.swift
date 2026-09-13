// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// The group of spoken terms and macOS actions owned by one wake profile.
///
/// A profile is the group. Saying the profile's wake phrase and then a term in
/// this set performs the bound action, so "mac" plus "play" and "mac" plus
/// "lock" are two bindings in one set rather than two profiles.
public struct SystemActionSet: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case bindings
    }

    /// Reasons a set cannot be used.
    public enum ValidationError: Error, Equatable, LocalizedError {
        /// The set binds no actions at all.
        case bindingRequired
        /// One term was bound to more than one action.
        case duplicatePhrase(String)

        /// A user-presentable explanation of the invalid set.
        public var errorDescription: String? {
            switch self {
            case .bindingRequired:
                "A system action profile needs at least one action."
            case let .duplicatePhrase(phrase):
                "“\(phrase)” is already used by another action in this profile."
            }
        }
    }

    /// The bindings, in the order the user arranged them.
    public private(set) var bindings: [SystemActionBinding]

    /// Creates a validated set.
    ///
    /// - Parameter bindings: The action bindings.
    /// - Throws: ``ValidationError/bindingRequired`` for an empty set, or
    ///   ``ValidationError/duplicatePhrase(_:)`` when one term would be ambiguous.
    public init(bindings: [SystemActionBinding]) throws {
        guard !bindings.isEmpty else { throw ValidationError.bindingRequired }

        var seen: Set<String> = []
        for binding in bindings {
            for (index, canonical) in binding.canonicalPhrases.enumerated() {
                guard seen.insert(canonical).inserted else {
                    throw ValidationError.duplicatePhrase(binding.phrases[index])
                }
            }
        }

        self.bindings = bindings
    }

    /// The set proposed for a newly created system-action profile.
    public static var defaultValue: SystemActionSet {
        // Suggested phrases are authored to be unique across the catalog, which
        // `defaultValue_BindsEveryDefaultActionWithoutConflict` pins.
        try! SystemActionSet(
            bindings: SystemAction.defaultActions.map { SystemActionBinding(suggestedFor: $0) })
    }

    /// The actions bound by this set, in binding order.
    public var actions: [SystemAction] {
        bindings.map(\.action)
    }

    /// Decodes a set, dropping any binding this build cannot perform.
    ///
    /// A profile written by a newer build may name an action this build does not
    /// have. Dropping that binding keeps the remaining ones usable instead of
    /// failing the whole profile back to its default.
    ///
    /// - Parameter decoder: The persisted set decoder.
    /// - Throws: A decoding error, or a validation error when nothing usable remains.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var list = try container.nestedUnkeyedContainer(forKey: .bindings)
        var decoded: [SystemActionBinding] = []
        while !list.isAtEnd {
            // A failed element still has to be consumed or the container stalls.
            if let binding = try? list.decode(SystemActionBinding.self) {
                decoded.append(binding)
            } else {
                _ = try? list.decode(UnknownBinding.self)
            }
        }
        try self.init(bindings: decoded)
    }

    /// Encodes the set.
    ///
    /// - Parameter encoder: The destination encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bindings, forKey: .bindings)
    }

    /// A placeholder that consumes an element this build cannot represent.
    private struct UnknownBinding: Decodable {}
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import YapOpsCore

/// One editable row binding spoken terms to a macOS action.
///
/// Terms are held as the user typed them, comma separated, so a half-finished
/// entry survives a redraw. Normalization happens when the profile is saved.
struct SystemActionDraft: Equatable, Identifiable {
    /// The stable row identity used by the editor's list.
    let id: UUID
    /// The macOS operation this row performs.
    var action: SystemAction
    /// The comma-separated spoken terms.
    var terms: String

    init(id: UUID = UUID(), action: SystemAction, terms: String) {
        self.id = id
        self.action = action
        self.terms = terms
    }

    init(binding: SystemActionBinding) {
        id = binding.id
        action = binding.action
        terms = binding.phrases.joined(separator: ", ")
    }

    /// Creates a row seeded with the action's suggested terms.
    init(suggestedFor action: SystemAction) {
        self.init(
            action: action,
            terms: action.suggestedPhrases.joined(separator: ", "))
    }

    /// The individual terms, split on commas and trimmed.
    var termList: [String] {
        terms
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// The editable form of a profile's system-action bindings.
struct SystemActionSetDraft: Equatable {
    /// The rows in the order the user arranged them.
    var rows: [SystemActionDraft]

    init(rows: [SystemActionDraft]) {
        self.rows = rows
    }

    init(set: SystemActionSet) {
        rows = set.bindings.map(SystemActionDraft.init(binding:))
    }

    /// The draft proposed for a newly created system-action profile.
    static var defaultValue: SystemActionSetDraft {
        SystemActionSetDraft(set: .defaultValue)
    }

    /// The catalog actions this draft has not bound yet.
    var unboundActions: [SystemAction] {
        let bound = Set(rows.map(\.action))
        return SystemAction.allCases.filter { !bound.contains($0) }
    }

    /// Appends a row for an action, seeded with its suggested terms.
    ///
    /// - Parameter action: The action to bind.
    mutating func add(_ action: SystemAction) {
        guard !rows.contains(where: { $0.action == action }) else { return }
        rows.append(SystemActionDraft(suggestedFor: action))
    }

    /// Removes a row.
    ///
    /// - Parameter id: The row identity to remove.
    mutating func remove(_ id: UUID) {
        rows.removeAll { $0.id == id }
    }

    /// Builds the validated set this draft describes.
    ///
    /// - Returns: The validated bindings.
    /// - Throws: A binding or set validation error.
    func validatedSet() throws -> SystemActionSet {
        try SystemActionSet(bindings: rows.map { row in
            try SystemActionBinding(
                id: row.id,
                action: row.action,
                phrases: row.termList)
        })
    }
}

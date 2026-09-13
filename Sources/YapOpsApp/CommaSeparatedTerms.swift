// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// Translates between a list of spoken terms and the one comma-separated line
/// the editors let the user type.
///
/// Settings edits spoken vocabulary in a single field wherever a list is short:
/// system-action terms and the phrases that end a conversation both read as one
/// line. Parsing is deliberately forgiving — the raw text is what the user
/// typed, so stray spaces and empty slots left mid-edit simply drop out.
enum CommaSeparatedTerms {
    /// Splits a typed line into individual terms.
    ///
    /// - Parameter text: The line as typed, terms separated by commas.
    /// - Returns: The non-empty terms, trimmed and in typed order.
    static func list(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Renders terms as the line an editor shows.
    ///
    /// - Parameter terms: The terms to display.
    /// - Returns: The terms joined by a comma and a space.
    static func text(_ terms: [String]) -> String {
        terms.joined(separator: ", ")
    }
}

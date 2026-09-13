// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI
import YapOpsCore

/// Edits the spoken phrases that end a live agent conversation and close its
/// panel — "cancel" and "stop" today, plus natural closers like "thank you".
///
/// The phrases read as one comma-separated line, the same shape system-action
/// terms use, so the whole vocabulary is visible and editable in one place.
/// Text is held as typed and parsed on the way out, so a trailing comma or a
/// half-typed phrase survives a redraw. Clearing the field saves an empty list:
/// `AppPreferences.terminalPhrases` only falls back to the built-in defaults
/// when the setting has never been saved at all.
struct TerminalPhrasesEditor: View {
    @Binding var phrases: [String]
    @State private var text: String

    init(phrases: Binding<[String]>) {
        _phrases = phrases
        _text = State(initialValue: CommaSeparatedTerms.text(phrases.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.row) {
            // A bare TextField(_:text:) renders its title as a persistent row
            // label inside a Form/Section, repeating the section header.
            // `prompt:` is the placeholder that disappears once text is typed.
            TextField("", text: $text, prompt: Text("Phrases, comma separated"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Conversation phrases, comma separated")

            Button("Reset to defaults") {
                text = CommaSeparatedTerms.text(AppPreferences.defaultTerminalPhrases)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .onChange(of: text) { phrases = CommaSeparatedTerms.list(text) }
        .onChange(of: phrases) { adoptExternalChange() }
    }

    /// Rewrites the field when the list changes underneath it — a reload after
    /// a save — while leaving text alone when it already describes that list,
    /// so an edit in progress is never reformatted under the cursor.
    private func adoptExternalChange() {
        guard CommaSeparatedTerms.list(text) != phrases else { return }
        text = CommaSeparatedTerms.text(phrases)
    }
}

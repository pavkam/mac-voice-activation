// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI
import YapOpsCore

/// Edits the spoken phrases that end a live agent conversation and close its
/// panel — "cancel" and "stop" today, plus natural closers like "thank you".
///
/// A blank row is dropped on save rather than matching every utterance, so
/// clearing a field to delete it is safe. An explicitly saved empty list
/// stays empty: `AppPreferences.terminalPhrases` only falls back to the
/// built-in defaults when the setting has never been saved at all.
struct TerminalPhrasesEditor: View {
    @Binding var phrases: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.row) {
            ForEach(phrases.indices, id: \.self) { index in
                HStack(spacing: Design.Space.small) {
                    // A bare TextField(_:text:) renders its title as a
                    // persistent row label inside a Form/Section, not a
                    // placeholder — nine rows all captioned "Phrase" the
                    // header already named. `prompt:` is the placeholder that
                    // actually disappears once a phrase is typed.
                    TextField("", text: $phrases[index], prompt: Text("Phrase"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Terminal phrase \(index + 1)")
                    Button(role: .destructive) {
                        phrases.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove phrase")
                }
            }

            HStack(spacing: Design.Space.card) {
                Button {
                    phrases.append("")
                } label: {
                    Label("Add phrase", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)

                Button("Reset to defaults") {
                    phrases = AppPreferences.defaultTerminalPhrases
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }
}

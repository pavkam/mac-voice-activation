// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI
import YapOpsCore

/// Edits the macOS actions a system-action profile can perform.
struct SystemActionSettingsView: View {
    @Binding var profile: WakeProfileDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if profile.systemActions.rows.isEmpty {
                emptyState
            } else {
                ForEach($profile.systemActions.rows) { $row in
                    SystemActionRow(row: $row) {
                        profile.systemActions.remove(row.id)
                    }
                }
            }
            addMenu
            Text(exampleHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Actions").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text("Separate alternative terms with commas.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        Text("This profile performs nothing until you add an action.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var addMenu: some View {
        let unbound = profile.systemActions.unboundActions
        Menu {
            ForEach(SystemAction.Category.allCases, id: \.self) { category in
                let available = category.actions.filter(unbound.contains)
                if !available.isEmpty {
                    Section(category.title) {
                        ForEach(available, id: \.self) { action in
                            Button {
                                profile.systemActions.add(action)
                            } label: {
                                Label(action.title, systemImage: action.symbolName)
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Add action", systemImage: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(unbound.isEmpty)
    }

    /// A worked example using the profile's own wake phrase and first term.
    private var exampleHint: String {
        let phrase = profile.wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !phrase.isEmpty,
            let term = profile.systemActions.rows.first?.termList.first
        else {
            return "Say the wake phrase followed by one of these terms."
        }
        return "Say the wake phrase then a term, for example “\(phrase) \(term)”."
    }
}

/// One action row: what it does, and the terms that invoke it.
private struct SystemActionRow: View {
    @Binding var row: SystemActionDraft
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Label {
                Text(row.action.title)
            } icon: {
                Image(systemName: row.action.symbolName)
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.titleAndIcon)
            .frame(width: 168, alignment: .leading)

            // The row already names the action, so a repeated field label would
            // be noise; the prompt disappears once terms are entered.
            TextField("", text: $row.terms, prompt: Text("Terms, comma separated"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)

            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(row.action.title)")
        }
    }
}

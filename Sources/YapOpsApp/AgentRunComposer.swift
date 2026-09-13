// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI
import YapOpsCore

/// The conversation panel's input dock.
///
/// The panel previously had no input at all: you could speak to a conversation
/// but not type to it, and the microphone had no control inside the panel. That
/// is fine until recognition mishears a path or you need to paste something,
/// at which point the conversation is unusable.
///
/// Voice stays primary — the filled accent mic leads, and a live transcript
/// replaces the field as words land — with typing as the fallback. The composer
/// stays open while the agent works, because YapOps accepts follow-ups mid-turn.
/// "End conversation" moves to a quiet secondary line beneath it, since ending
/// is rare and sending is not.
struct AgentRunComposer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.profileAccent) private var accent

    let snapshot: AgentRunSnapshot
    let onSubmit: (String) -> Void
    let onToggleMicrophone: () -> Void
    let onStop: () -> Void
    let onEndConversation: () -> Void

    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: Design.Space.row) {
            inputPill
            secondaryLine
        }
        .padding(.horizontal, Design.Space.panelContent)
        .padding(.vertical, Design.Space.card)
    }

    private var inputPill: some View {
        HStack(spacing: Design.Space.section) {
            microphoneButton

            if let transcript = liveTranscript {
                // A live transcript replaces the field rather than sitting beside
                // it: two competing inputs would make it unclear which one the
                // agent is going to receive.
                Text(transcript)
                    .font(Design.Text.rowTranscript)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                    .accessibilityLabel("Heard: \(transcript)")
            } else {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($isFieldFocused)
                    .onSubmit(submit)
                    .accessibilityLabel("Message this conversation")
            }

            trailingButton
        }
        .padding(.horizontal, Design.Space.card)
        .padding(.vertical, Design.Space.section)
        .background(
            .primary.opacity(Design.Alpha.fillField),
            in: RoundedRectangle(cornerRadius: Design.Radius.message, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.message, style: .continuous)
                .stroke(pillBorder, lineWidth: Design.Border.thin)
        }
        .animation(
            Design.Motion.resolved(Design.Motion.snappy, reduceMotion: reduceMotion),
            value: liveTranscript)
    }

    private var microphoneButton: some View {
        Button(action: onToggleMicrophone) {
            Image(systemName: snapshot.phase.acceptsSpokenFollowUp ? "mic.fill" : "mic.slash.fill")
                .font(Design.Text.glyph(Design.Glyph.row))
                .foregroundStyle(snapshot.phase.acceptsSpokenFollowUp ? Color.white : Color.secondary)
                .frame(width: Design.Layout.hitTarget, height: Design.Layout.hitTarget)
                .background(microphoneFill, in: Circle())
        }
        .buttonStyle(.plain)
        .help(snapshot.phase.microphoneActionLabel)
        .accessibilityLabel(snapshot.phase.microphoneActionLabel)
    }

    @ViewBuilder
    private var trailingButton: some View {
        if snapshot.phase == .running {
            // Stop takes Send's place while the agent holds the turn: the
            // primary action is always the one that changes the current state.
            Button(action: onStop) {
                Image(systemName: "stop.circle.fill")
                    .font(Design.Text.glyph(Design.Glyph.status))
                    .foregroundStyle(Design.Color.danger)
            }
            .buttonStyle(.plain)
            .help("Stop turn")
            .accessibilityLabel("Stop turn")
        } else {
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Design.Text.glyph(Design.Glyph.status))
                    .foregroundStyle(canSubmit ? accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: [])
            .help("Send")
            .accessibilityLabel("Send")
        }
    }

    private var secondaryLine: some View {
        HStack {
            Spacer()
            Button("End conversation", systemImage: "rectangle.portrait.and.arrow.right") {
                onEndConversation()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("End this conversation")
        }
    }

    /// The overlay's transcript, mirrored here while words are arriving.
    private var liveTranscript: String? {
        let voice = snapshot.voiceInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot.phase.acceptsSpokenFollowUp, !voice.isEmpty else { return nil }
        return voice
    }

    private var placeholder: String {
        switch snapshot.phase {
        case .running: "Add to this turn"
        case .paused: "Microphone off · Type instead"
        default: "Ask a follow-up"
        }
    }

    private var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var microphoneFill: Color {
        snapshot.phase.acceptsSpokenFollowUp ? accent : Color.primary.opacity(Design.Alpha.fillQuaternary)
    }

    private var pillBorder: Color {
        isFieldFocused
            ? accent.opacity(Design.Alpha.selectionBorder)
            : Color.white.opacity(Design.Alpha.hairlineCard)
    }

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft = ""
        onSubmit(trimmed)
    }
}

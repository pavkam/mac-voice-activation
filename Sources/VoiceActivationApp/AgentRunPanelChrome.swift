// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI
import VoiceActivationCore

extension AgentRunPanelView {
    func actions(_ snapshot: AgentRunSnapshot) -> some View {
        HStack(spacing: 8) {
            leadingActions(snapshot)
            Spacer()
            trailingActions(snapshot)
        }
        .animation(actionDockAnimation, value: snapshot.phase)
    }

    /// Builds the phase-specific controls on the leading edge of the footer.
    @ViewBuilder
    func leadingActions(_ snapshot: AgentRunSnapshot) -> some View {
        if snapshot.phase == .running {
            Button("Stop turn", systemImage: "stop.circle.fill") {
                model.onAction?(.cancel(runID: snapshot.runID))
            }
            .buttonStyle(AgentRunActionButtonStyle(role: .danger, tint: .red))
            .transition(actionDockTransition)
        } else if snapshot.phase == .cancelling {
            Button("Cancelling…", systemImage: "clock") {}
                .buttonStyle(AgentRunActionButtonStyle(role: .subtle, tint: accent))
                .disabled(true)
                .transition(actionDockTransition)
        }
    }

    /// Builds the live or terminal controls on the trailing edge of the footer.
    @ViewBuilder
    func trailingActions(_ snapshot: AgentRunSnapshot) -> some View {
        if !snapshot.phase.isTerminal {
            Button("End conversation", systemImage: "rectangle.portrait.and.arrow.right") {
                model.onAction?(.endConversation(runID: snapshot.runID))
            }
            .buttonStyle(AgentRunActionButtonStyle(role: .subtle, tint: accent))
            .transition(actionDockTransition)
        } else {
            HStack(spacing: 8) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    model.onAction?(.delete(runID: snapshot.runID))
                }
                .buttonStyle(AgentRunActionButtonStyle(role: .danger, tint: .red))
                Button("Copy output", systemImage: "doc.on.doc") {
                    model.onAction?(.copy(runID: snapshot.runID))
                }
                .buttonStyle(AgentRunActionButtonStyle(role: .subtle, tint: accent))
                Button("Close", systemImage: "xmark") {
                    model.onAction?(.close(runID: snapshot.runID))
                }
                .buttonStyle(AgentRunActionButtonStyle(role: .accent, tint: accent))
            }
            .transition(actionDockTransition)
        }
    }

    /// The action replacement animation, shortened when reduced motion is enabled.
    var actionDockAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.14) : .snappy(duration: 0.30)
    }

    /// Slides footer controls through the panel edge while cross-fading their state.
    var actionDockTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .scale(scale: 0.96, anchor: .bottom))
                .combined(with: .opacity),
            removal: .move(edge: .bottom)
                .combined(with: .scale(scale: 0.98, anchor: .bottom))
                .combined(with: .opacity))
    }

    func actionDock(_ snapshot: AgentRunSnapshot) -> some View {
        actions(snapshot)
        .padding(.horizontal, 18)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .background {
            LinearGradient(
                colors: [.white.opacity(0.055), .black.opacity(0.035)],
                startPoint: .top,
                endPoint: .bottom)
        }
        .overlay(alignment: .top) {
            panelSeparator
        }
    }

    func userBubble(_ text: String, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Label(label, systemImage: "person.fill")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(accent.opacity(0.92))
                .textCase(.uppercase)
                .tracking(0.9)

            Text(text)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .lineSpacing(2)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [accent.opacity(0.30), accentHighlight.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(accent.opacity(0.28), lineWidth: 0.7)
                }
                .shadow(color: accent.opacity(0.10), radius: 8, y: 3)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 74)
    }

    var miniAgentMark: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(
                    colors: [accent, accentHighlight, accent.opacity(0.72), accent],
                    center: .center))
            Circle().stroke(.white.opacity(0.28), lineWidth: 0.7)
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 27, height: 27)
        .shadow(color: accent.opacity(0.24), radius: 6, y: 2)
        .accessibilityHidden(true)
    }

    var panelSeparator: some View {
        LinearGradient(
            colors: [.clear, .white.opacity(0.14), accent.opacity(0.22), .clear],
            startPoint: .leading,
            endPoint: .trailing)
            .frame(height: 0.7)
    }

    func sectionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(1)
    }

    var accent: Color {
        model.snapshot?.accent.swiftUIColor ?? .blue
    }

    var panelSize: CGSize {
        model.isMinimized
            ? AgentRunPanelLayout.compactSize
            : AgentRunPanelLayout.expandedSize
    }

    var accentHighlight: Color {
        switch model.snapshot?.accent ?? .blue {
        case .cyan: .blue
        case .blue: .indigo
        case .purple: .pink
        case .pink: .purple
        case .orange: .pink
        case .green: .cyan
        }
    }

    func compactStatus(_ snapshot: AgentRunSnapshot) -> String {
        if !snapshot.permissions.isEmpty {
            return "Permission needed"
        }
        if !snapshot.voiceInput.isEmpty {
            return snapshot.voiceInput
        }
        for item in snapshot.timeline.reversed() {
            switch item {
            case let .message(message):
                return message.text
            case let .userMessage(message):
                return "You: \(message.text)"
            case let .thinking(thinking):
                return thinking.isWorking ? "Thinking…" : "Thinking complete"
            case .omitted:
                continue
            }
        }
        return phaseLabel(snapshot.phase)
    }

    func phaseLabel(_ phase: AgentRunPhase) -> String {
        switch phase {
        case .listening: "Listening"
        case .running: "Working"
        case .cancelling: "Cancelling"
        case let .completed(reason): reason == .cancelled ? "Cancelled" : "Completed"
        case .failed: "Failed"
        }
    }

    func phaseSymbol(_ phase: AgentRunPhase) -> String {
        switch phase {
        case .listening: "waveform.badge.mic"
        case .running: "sparkles"
        case .cancelling: "clock.arrow.circlepath"
        case let .completed(reason): reason == .cancelled ? "xmark" : "checkmark"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    func planSymbol(_ status: AgentPlanStatus) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "circle.dotted"
        case .completed: "checkmark.circle.fill"
        }
    }

    func toolSymbol(_ tool: AgentToolPresentation) -> String {
        switch tool.status {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .inProgress: "gearshape.2.fill"
        case .pending, nil: tool.isSettled ? "checkmark.circle" : "circle.dotted"
        }
    }

    func toolSummary(_ tool: AgentToolPresentation) -> String {
        switch tool.status {
        case .failed:
            tool.kind.map { "\(toolKindLabel($0)) failed" } ?? "Tool failed"
        case .completed:
            tool.kind.map { "\(toolKindLabel($0)) complete" } ?? "Completed"
        case .pending, .inProgress, nil:
            tool.isSettled ? "Finished" : "Working…"
        }
    }

    func toolKindLabel(_ kind: AgentToolKind) -> String {
        switch kind {
        case .read: "Read"
        case .edit: "Edit"
        case .delete: "Delete"
        case .move: "Move"
        case .search: "Search"
        case .execute: "Command"
        case .think: "Reasoning"
        case .fetch: "Fetch"
        case .switchMode: "Mode change"
        case .other: "Tool"
        }
    }
}

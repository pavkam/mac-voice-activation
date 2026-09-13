// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI
import YapOpsCore

extension AgentRunPanelView {
    func actions(_ snapshot: AgentRunSnapshot) -> some View {
        HStack(spacing: 8) {
            leadingActions(snapshot)
            Spacer()
            trailingActions(snapshot)
        }
        .animation(actionDockAnimation, value: snapshot.phase)
    }

    @ViewBuilder
    func leadingActions(_ snapshot: AgentRunSnapshot) -> some View {
        if snapshot.phase == .running || snapshot.phase == .listening {
            Button {
                model.onAction?(.cancel(runID: snapshot.runID))
            } label: {
                Label(snapshot.phase == .listening ? "Stop listening" : "Stop turn",
                    systemImage: "stop.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .transition(actionDockTransition)
        } else if snapshot.phase == .paused {
            Button("Resume listening", systemImage: "mic") {
                model.onAction?(.resumeListening(runID: snapshot.runID))
            }
            .buttonStyle(.bordered)
            .transition(actionDockTransition)
        } else if snapshot.phase == .cancelling {
            Button("Cancelling…", systemImage: "clock") {}
                .buttonStyle(.bordered)
                .disabled(true)
                .transition(actionDockTransition)
        }
    }

    @ViewBuilder
    func trailingActions(_ snapshot: AgentRunSnapshot) -> some View {
        if !snapshot.phase.isTerminal {
            Button("End conversation", systemImage: "rectangle.portrait.and.arrow.right") {
                model.onAction?(.endConversation(runID: snapshot.runID))
            }
            .buttonStyle(.bordered)
            .transition(actionDockTransition)
        } else if snapshot.canCloseOrDelete {
            HStack(spacing: 8) {
                Button {
                    model.onAction?(.delete(runID: snapshot.runID))
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityHint("Permanently deletes this conversation")
                Button("Copy output", systemImage: "doc.on.doc") {
                    model.onAction?(.copy(runID: snapshot.runID))
                }
                .buttonStyle(.bordered)
                Button("Close", systemImage: "xmark") {
                    model.onAction?(.close(runID: snapshot.runID))
                }
                .buttonStyle(.borderedProminent)
            }
            .transition(actionDockTransition)
        }
    }

    var actionDockAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.14) : .snappy(duration: 0.30)
    }

    var actionDockTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .bottom).combined(with: .opacity))
    }

    /// The bottom of the panel.
    ///
    /// While a conversation is live the composer owns it: sending is the action
    /// you want, and the old dock offered everything except that. Terminal
    /// phases keep the dock, because Delete / Copy output / Close is all that
    /// remains to do.
    @ViewBuilder
    func actionDock(_ snapshot: AgentRunSnapshot) -> some View {
        if snapshot.phase.isTerminal {
            actions(snapshot)
                .controlSize(.small)
                .padding(.horizontal, Design.Space.panelGutter)
                .padding(.vertical, Design.Space.cardTight)
                .overlay(alignment: .top) { panelSeparator }
        } else {
            AgentRunComposer(
                snapshot: snapshot,
                onSubmit: { text in
                    model.onAction?(.submitFollowUp(runID: snapshot.runID, text: text))
                },
                onToggleMicrophone: {
                    if snapshot.phase == .paused {
                        model.onAction?(.resumeListening(runID: snapshot.runID))
                    } else {
                        model.onAction?(.cancel(runID: snapshot.runID))
                    }
                },
                onStop: {
                    model.onAction?(.cancel(runID: snapshot.runID))
                },
                onEndConversation: {
                    model.onAction?(.endConversation(runID: snapshot.runID))
                })
                .overlay(alignment: .top) { panelSeparator }
        }
    }

    func userBubble(_ text: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: "person.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(text)
                .font(.callout)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: Design.Radius.innerCard))
        .accessibilityElement(children: .combine)
    }

    var panelSeparator: some View {
        Divider().accessibilityHidden(true)
    }

    func sectionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    var accent: Color {
        model.snapshot?.accent.swiftUIColor ?? .blue
    }

    var panelSize: CGSize {
        model.isMinimized ? AgentRunPanelLayout.compactSize : model.expandedSize
    }

    func compactStatus(_ snapshot: AgentRunSnapshot) -> String {
        if !snapshot.permissions.isEmpty {
            return "Permission needed"
        }
        if !snapshot.voiceInput.isEmpty {
            return snapshot.voiceInput
        }
        if snapshot.hasActiveBackgroundTasks {
            return "Working in background"
        }
        for item in snapshot.timeline.reversed() {
            switch item {
            case let .message(message):
                return message.text
            case let .userMessage(message):
                return "You: \(message.text)"
            case let .thinking(thinking):
                return thinking.isWorking ? "Thinking…" : "Thinking complete"
            case .historyBoundary, .omitted:
                continue
            }
        }
        return phaseLabel(snapshot.phase)
    }

    func phaseLabel(_ phase: AgentRunPhase) -> String {
        switch phase {
        case .listening: "Listening"
        case .paused: "Paused · Microphone off"
        case .running: "Working"
        case .cancelling: "Cancelling"
        case let .completed(reason): reason == .cancelled ? "Cancelled" : "Completed"
        case .failed: "Failed"
        }
    }

    func panelPhaseLabel(_ snapshot: AgentRunSnapshot) -> String {
        snapshot.hasActiveBackgroundTasks && snapshot.phase != .running
            ? "Working in background"
            : phaseLabel(snapshot.phase)
    }

    func planSymbol(_ status: AgentPlanStatus) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "circle.dotted"
        case .completed: "checkmark.circle.fill"
        case .interrupted: "exclamationmark.circle"
        }
    }

    func toolSymbol(_ tool: AgentToolPresentation) -> String {
        switch tool.status {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .inProgress: "gearshape.2"
        case .interrupted: "exclamationmark.circle"
        case .pending, nil: tool.isSettled ? "checkmark.circle" : "circle.dotted"
        }
    }

    func toolSummary(_ tool: AgentToolPresentation) -> String {
        switch tool.status {
        case .failed:
            tool.kind.map { "\(toolKindLabel($0)) failed" } ?? "Tool failed"
        case .interrupted:
            tool.kind.map { "\(toolKindLabel($0)) interrupted" } ?? "Interrupted"
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

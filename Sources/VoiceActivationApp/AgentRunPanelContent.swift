// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI
import VoiceActivationCore

extension AgentRunPanelView {
    func requestCard(_ snapshot: AgentRunSnapshot) -> some View {
        userBubble(snapshot.prompt, label: "You")
    }

    @ViewBuilder
    func timeline(_ snapshot: AgentRunSnapshot) -> some View {
        if snapshot.timeline.isEmpty,
           snapshot.phase == .running || snapshot.phase == .cancelling
        {
            HStack(spacing: 10) {
                AgentRunWorkingGlyph(tint: accent, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.phase == .cancelling ? "Wrapping up" : "Warming up")
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text(snapshot.phase == .cancelling
                        ? "Waiting for the agent to stop safely"
                        : "Connecting to \(snapshot.providerName)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(12)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        } else {
            ForEach(snapshot.timeline) { item in
                switch item {
                case .omitted:
                    Label("Earlier activity omitted", systemImage: "ellipsis.circle")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case let .message(message):
                    messageBlock(message)
                case let .userMessage(message):
                    userMessageBlock(message)
                case let .thinking(thinking):
                    thinkingCard(thinking)
                }
            }
        }
    }

    func messageBlock(_ message: AgentMessagePresentation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if message.kind == .response {
                miniAgentMark
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(
                    message.kind == .thought
                        ? "Thinking"
                        : model.snapshot?.providerName ?? "Agent",
                    symbol: message.kind == .thought ? "brain.head.profile" : "sparkles")
                AgentMarkdownView(markdown: message.text)
                    .foregroundStyle(message.kind == .thought ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .tint(accent)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(.white.opacity(message.kind == .thought ? 0.035 : 0.055))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, message.kind == .response ? 40 : 18)
    }

    func userMessageBlock(_ message: AgentUserMessagePresentation) -> some View {
        userBubble(message.text, label: "You")
    }

    @ViewBuilder
    func noticeCards(_ snapshot: AgentRunSnapshot) -> some View {
        ForEach(Array(snapshot.notices.enumerated()), id: \.offset) { _, notice in
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
                Text(notice)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                LinearGradient(
                    colors: [.orange.opacity(0.12), .white.opacity(0.025)],
                    startPoint: .leading,
                    endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.orange.opacity(0.18), lineWidth: 0.7)
            }
        }
    }

    @ViewBuilder
    func failureCard(_ snapshot: AgentRunSnapshot) -> some View {
        if case let .failed(message) = snapshot.phase {
            HStack(alignment: .top, spacing: 11) {
                ZStack {
                    Circle().fill(.red.opacity(0.16))
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.red)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent stopped")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    Text(message)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [.red.opacity(0.16), .pink.opacity(0.045)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(.red.opacity(0.24), lineWidth: 0.8)
            }
        }
    }

}

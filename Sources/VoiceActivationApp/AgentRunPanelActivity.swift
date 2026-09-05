// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI
import VoiceActivationCore

extension AgentRunPanelView {
    @ViewBuilder
    func plan(_ snapshot: AgentRunSnapshot) -> some View {
        if !snapshot.plan.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Plan", symbol: "list.bullet.clipboard")
                ForEach(Array(snapshot.plan.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: planSymbol(entry.status))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(entry.status == .inProgress ? accent : .secondary)
                            .symbolEffect(
                                .variableColor.iterative,
                                isActive: entry.status == .inProgress)
                        Text(entry.content)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(
                                entry.status == .completed ? .secondary : .primary)
                    }
                }
            }
            .padding(12)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(0.08), lineWidth: 0.7)
            }
        }
    }

    func thinkingCard(_ thinking: AgentThinkingPresentation) -> some View {
        let isExpanded = model.isThinkingExpanded(thinkingID: thinking.id)
        let detailCount = thinking.details.count
        let detailCountLabel = thinking.omittedDetailCount > 0
            ? "\(detailCount)+ steps"
            : "\(detailCount) \(detailCount == 1 ? "step" : "steps")"
        let detailSummary = thinking.isWorking && detailCount == 0
            ? "Starting the agent"
            : "\(detailCountLabel)  •  \(isExpanded ? "Hide" : "Show") details"
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.24)) {
                    model.toggleThinkingDetails(thinkingID: thinking.id)
                }
            } label: {
                HStack(alignment: .center, spacing: 11) {
                    thinkingActivityIcon(thinking)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(thinking.isWorking ? "Thinking…" : "Thinking")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(thinking.hasFailedTool ? .red : .primary)
                        Text(detailSummary)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    panelSeparator
                    if thinking.omittedDetailCount > 0 {
                        Label(
                            "\(thinking.omittedDetailCount) earlier steps omitted",
                            systemImage: "ellipsis.circle")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(thinking.details) { detail in
                        thinkingDetail(detail)
                    }
                }
                .padding(.top, 10)
                .padding(.leading, 9)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(accent.opacity(0.20))
                        .frame(width: 2)
                        .padding(.top, 14)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, thinking.isWorking ? 11 : 9)
        .background(
            LinearGradient(
                colors: thinking.hasFailedTool
                    ? [.red.opacity(0.14), .red.opacity(0.035)]
                    : [accent.opacity(thinking.isWorking ? 0.15 : 0.085), .white.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    thinking.hasFailedTool
                        ? Color.red.opacity(0.24)
                        : accent.opacity(thinking.isWorking ? 0.24 : 0.12),
                    lineWidth: 0.7)
        }
        .shadow(
            color: thinking.isWorking ? accent.opacity(0.10) : .clear,
            radius: 10,
            y: 4)
        .animation(.snappy(duration: 0.24), value: thinking)
    }

    @ViewBuilder
    func thinkingActivityIcon(_ thinking: AgentThinkingPresentation) -> some View {
        if thinking.isWorking {
            AgentRunWorkingGlyph(tint: accent, size: 28)
        } else {
            ZStack {
                Circle().fill((thinking.hasFailedTool ? Color.red : accent).opacity(0.13))
                Image(systemName: thinking.hasFailedTool ? "exclamationmark" : "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(thinking.hasFailedTool ? .red : accent)
            }
            .frame(width: 28, height: 28, alignment: .topLeading)
        }
    }

    @ViewBuilder
    func thinkingDetail(_ detail: AgentThinkingDetail) -> some View {
        switch detail {
        case let .thought(message):
            VStack(alignment: .leading, spacing: 5) {
                sectionLabel("Reasoning", symbol: "brain.head.profile")
                AgentMarkdownView(markdown: message.text)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.leading, 6)
        case let .tool(tool):
            HStack(alignment: .top, spacing: 9) {
                toolActivityIcon(tool)
                VStack(alignment: .leading, spacing: 3) {
                    Text(toolSummary(tool))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(tool.status == .failed ? .red : .secondary)
                        .textCase(.uppercase)
                    Text(tool.title)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 6)
        }
    }

    @ViewBuilder
    func toolActivityIcon(_ tool: AgentToolPresentation) -> some View {
        if tool.isWorking {
            AgentRunWorkingGlyph(tint: accent, size: 19)
        } else {
            Image(systemName: toolSymbol(tool))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tool.status == .failed ? .red : accent)
                .frame(width: 18, height: 18, alignment: .topLeading)
        }
    }

    @ViewBuilder
    func permissions(_ snapshot: AgentRunSnapshot) -> some View {
        ForEach(snapshot.permissions) { permission in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        Circle().fill(accent.opacity(0.17))
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Permission requested")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)
                            .textCase(.uppercase)
                            .tracking(0.8)
                        Text(permission.toolTitle)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text("Say “allow”, “allow all”, “deny”, or “deny all”.")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    ForEach(permission.options, id: \.id) { option in
                        Button(option.label) {
                            model.selectPermission(permission, optionID: option.id)
                        }
                        .buttonStyle(AgentRunActionButtonStyle(
                            role: option.kind == .allowOnce || option.kind == .allowAlways
                                ? .accent
                                : .subtle,
                            tint: option.kind == .allowOnce || option.kind == .allowAlways
                                ? accent
                                : .red))
                        .disabled(
                            permission.isResolving
                                || model.resolvingPermissions.contains(permission.key))
                    }
                }
            }
            .padding(13)
            .background(
                LinearGradient(
                    colors: [accent.opacity(0.16), .white.opacity(0.035)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(accent.opacity(0.28), lineWidth: 0.8)
            }
            .shadow(color: accent.opacity(0.12), radius: 12, y: 5)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .animation(.snappy(duration: 0.2), value: snapshot.permissions.map(\.id))
    }

}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI
import VoiceActivationCore

struct AgentRunPanelView: View {
    @Bindable var model: AgentRunPanelModel

    var body: some View {
        let cornerRadius: CGFloat = model.isMinimized ? 24 : 30
        ZStack {
            AgentRunPanelBackdrop(
                accent: accent,
                highlight: accentHighlight,
                isActive: model.snapshot?.phase == .running,
                isCompact: model.isMinimized)
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.42),
                            .white.opacity(0.10),
                            accent.opacity(0.36),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    lineWidth: 0.8)
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .animation(
            .snappy(duration: AgentRunPanelLayout.transitionDuration),
            value: model.isMinimized)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = model.snapshot {
            if model.isMinimized {
                compactContent(snapshot)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else {
                expandedContent(snapshot)
                    .transition(.scale(scale: 0.98).combined(with: .opacity))
            }
        }
    }

    private func expandedContent(_ snapshot: AgentRunSnapshot) -> some View {
        VStack(spacing: 0) {
            header(snapshot)
            panelSeparator
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        requestCard(snapshot)
                        plan(snapshot)
                        timeline(snapshot)
                        noticeCards(snapshot)
                        failureCard(snapshot)
                        permissions(snapshot)
                        Color.clear.frame(height: 1).id("agent-run-bottom")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 14)
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(
                        0,
                        geometry.contentSize.height
                            - geometry.contentOffset.y
                            - geometry.containerSize.height)
                } action: { _, distanceFromBottom in
                    model.updateScrollGeometry(distanceFromBottom: distanceFromBottom)
                }
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    let wasUserScrolling = oldPhase == .interacting
                        || oldPhase == .decelerating
                    let isUserScrolling = newPhase == .interacting
                        || newPhase == .decelerating
                    guard wasUserScrolling || isUserScrolling else { return }
                    let geometry = context.geometry
                    let distance = max(
                        0,
                        geometry.contentSize.height
                            - geometry.contentOffset.y
                            - geometry.containerSize.height)
                    if isUserScrolling {
                        model.beginUserScrolling(distanceFromBottom: distance)
                    } else {
                        model.endUserScrolling(distanceFromBottom: distance)
                    }
                }
                .onChange(of: snapshot.timeline) {
                    followBottom(proxy)
                }
                .onChange(of: snapshot.notices) {
                    followBottom(proxy)
                }
                .onChange(of: snapshot.plan) {
                    followBottom(proxy)
                }
                .onChange(of: snapshot.permissions) {
                    followBottom(proxy)
                }
                .onChange(of: snapshot.voiceInput) {
                    followBottom(proxy)
                }
                .onChange(of: snapshot.phase) {
                    followBottom(proxy)
                }
            }
            conversationDock(snapshot)
        }
    }

    private func followBottom(_ proxy: ScrollViewProxy) {
        guard model.isAutoFollowing else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo("agent-run-bottom", anchor: .bottom)
        }
    }

    private func header(_ snapshot: AgentRunSnapshot) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 13) {
                phaseIcon(snapshot, size: 44, symbolSize: 17)

                VStack(alignment: .leading, spacing: 5) {
                    Text(snapshot.providerName)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .tracking(-0.25)
                    statusPill(snapshot.phase)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay { AgentRunPanelDragSurface() }

            AgentRunElapsedTimeView(
                phase: snapshot.phase,
                elapsedSeconds: snapshot.elapsedSeconds,
                startedAt: model.elapsedStartedAt)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(.white.opacity(0.055), in: Capsule())
                .overlay {
                    Capsule().stroke(.white.opacity(0.10), lineWidth: 0.7)
                }

            Button {
                model.onAction?(.minimize(runID: snapshot.runID))
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(AgentRunIconButtonStyle(tint: accent))
            .help("Minimize conversation")
            .accessibilityLabel("Minimize conversation")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background {
            LinearGradient(
                colors: [.white.opacity(0.045), .clear],
                startPoint: .top,
                endPoint: .bottom)
        }
    }

    private func compactContent(_ snapshot: AgentRunSnapshot) -> some View {
        HStack(spacing: 13) {
            HStack(spacing: 13) {
                phaseIcon(snapshot, size: 48, symbolSize: 18)

                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.providerName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(compactStatus(snapshot))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay { AgentRunPanelDragSurface() }

            AgentRunElapsedTimeView(
                phase: snapshot.phase,
                elapsedSeconds: snapshot.elapsedSeconds,
                startedAt: model.elapsedStartedAt)

            Button {
                model.onAction?(.restore(runID: snapshot.runID))
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(AgentRunIconButtonStyle(tint: accent))
            .help("Restore conversation")
            .accessibilityLabel("Restore conversation")
        }
        .padding(.horizontal, 15)
    }

    private func phaseIcon(
        _ snapshot: AgentRunSnapshot,
        size: CGFloat,
        symbolSize: CGFloat) -> some View
    {
        AgentRunPhaseOrb(
            symbol: phaseSymbol(snapshot.phase),
            accent: accent,
            highlight: accentHighlight,
            size: size,
            symbolSize: symbolSize,
            isActive: snapshot.phase == .running,
            isFailed: {
                if case .failed = snapshot.phase { return true }
                return false
            }())
    }

    private func requestCard(_ snapshot: AgentRunSnapshot) -> some View {
        userBubble(snapshot.prompt, label: "You")
    }

    @ViewBuilder
    private func timeline(_ snapshot: AgentRunSnapshot) -> some View {
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

    private func messageBlock(_ message: AgentMessagePresentation) -> some View {
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

    private func userMessageBlock(_ message: AgentUserMessagePresentation) -> some View {
        userBubble(message.text, label: "You")
    }

    @ViewBuilder
    private func noticeCards(_ snapshot: AgentRunSnapshot) -> some View {
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
    private func failureCard(_ snapshot: AgentRunSnapshot) -> some View {
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

    @ViewBuilder
    private func plan(_ snapshot: AgentRunSnapshot) -> some View {
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

    private func thinkingCard(_ thinking: AgentThinkingPresentation) -> some View {
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
    private func thinkingActivityIcon(_ thinking: AgentThinkingPresentation) -> some View {
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
    private func thinkingDetail(_ detail: AgentThinkingDetail) -> some View {
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
    private func toolActivityIcon(_ tool: AgentToolPresentation) -> some View {
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
    private func permissions(_ snapshot: AgentRunSnapshot) -> some View {
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

    @ViewBuilder
    private func voiceInput(_ snapshot: AgentRunSnapshot) -> some View {
        if !snapshot.phase.isTerminal {
            HStack(alignment: .center, spacing: 11) {
                ZStack {
                    Circle()
                        .fill(AngularGradient(
                            colors: [accent, accentHighlight, accent],
                            center: .center))
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                }
                .frame(width: 30, height: 30)
                .shadow(color: accent.opacity(0.28), radius: 7)

                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.voiceInput.isEmpty ? "Listening for you…" : snapshot.voiceInput)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(snapshot.voiceInput.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                        .contentTransition(.interpolate)
                    Text("Speak a follow-up  •  say “stop” to finish")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                LinearGradient(
                    colors: [accent.opacity(0.13), .white.opacity(0.035)],
                    startPoint: .leading,
                    endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(accent.opacity(0.20), lineWidth: 0.7)
            }
        }
    }

    private func actions(_ snapshot: AgentRunSnapshot) -> some View {
        HStack(spacing: 8) {
            if snapshot.phase == .running {
                Button("Stop turn", systemImage: "stop.circle.fill") {
                    model.onAction?(.cancel(runID: snapshot.runID))
                }
                .buttonStyle(AgentRunActionButtonStyle(role: .danger, tint: .red))
            } else if snapshot.phase == .cancelling {
                Button("Cancelling…", systemImage: "clock") {}
                    .buttonStyle(AgentRunActionButtonStyle(role: .subtle, tint: accent))
                    .disabled(true)
            }
            Spacer()
            if !snapshot.phase.isTerminal {
                Button("End conversation", systemImage: "rectangle.portrait.and.arrow.right") {
                    model.onAction?(.endConversation(runID: snapshot.runID))
                }
                .buttonStyle(AgentRunActionButtonStyle(role: .subtle, tint: accent))
            } else {
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
        }
    }

    private func conversationDock(_ snapshot: AgentRunSnapshot) -> some View {
        VStack(spacing: 9) {
            if !snapshot.phase.isTerminal {
                voiceInput(snapshot)
            }
            actions(snapshot)
        }
        .padding(.horizontal, 18)
        .padding(.top, snapshot.phase.isTerminal ? 11 : 9)
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

    private func userBubble(_ text: String, label: String) -> some View {
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

    private var miniAgentMark: some View {
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

    private func statusPill(_ phase: AgentRunPhase) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(phaseTint(phase))
                .frame(width: 5, height: 5)
                .shadow(color: phaseTint(phase).opacity(0.65), radius: 4)
            Text(phaseLabel(phase))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(.white.opacity(0.055), in: Capsule())
        .overlay {
            Capsule().stroke(.white.opacity(0.09), lineWidth: 0.6)
        }
        .fixedSize()
    }

    private var panelSeparator: some View {
        LinearGradient(
            colors: [.clear, .white.opacity(0.14), accent.opacity(0.22), .clear],
            startPoint: .leading,
            endPoint: .trailing)
            .frame(height: 0.7)
    }

    private func sectionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(1)
    }

    private var accent: Color {
        model.snapshot?.accent.swiftUIColor ?? .blue
    }

    private var panelSize: CGSize {
        model.isMinimized
            ? AgentRunPanelLayout.compactSize
            : AgentRunPanelLayout.expandedSize
    }

    private var accentHighlight: Color {
        switch model.snapshot?.accent ?? .blue {
        case .cyan: .blue
        case .blue: .indigo
        case .purple: .pink
        case .pink: .purple
        case .orange: .pink
        case .green: .cyan
        }
    }

    private func compactStatus(_ snapshot: AgentRunSnapshot) -> String {
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

    private func phaseLabel(_ phase: AgentRunPhase) -> String {
        switch phase {
        case .listening: "Listening"
        case .running: "Working"
        case .cancelling: "Cancelling"
        case let .completed(reason): reason == .cancelled ? "Cancelled" : "Completed"
        case .failed: "Failed"
        }
    }

    private func phaseTint(_ phase: AgentRunPhase) -> Color {
        switch phase {
        case .listening: .cyan
        case .running: accent
        case .cancelling: .orange
        case let .completed(reason): reason == .cancelled ? .secondary : .green
        case .failed: .red
        }
    }

    private func phaseSymbol(_ phase: AgentRunPhase) -> String {
        switch phase {
        case .listening: "waveform.badge.mic"
        case .running: "sparkles"
        case .cancelling: "clock.arrow.circlepath"
        case let .completed(reason): reason == .cancelled ? "xmark" : "checkmark"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func planSymbol(_ status: AgentPlanStatus) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "circle.dotted"
        case .completed: "checkmark.circle.fill"
        }
    }

    private func toolSymbol(_ tool: AgentToolPresentation) -> String {
        switch tool.status {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .inProgress: "gearshape.2.fill"
        case .pending, nil: tool.isSettled ? "checkmark.circle" : "circle.dotted"
        }
    }

    private func toolSummary(_ tool: AgentToolPresentation) -> String {
        switch tool.status {
        case .failed:
            tool.kind.map { "\(toolKindLabel($0)) failed" } ?? "Tool failed"
        case .completed:
            tool.kind.map { "\(toolKindLabel($0)) complete" } ?? "Completed"
        case .pending, .inProgress, nil:
            tool.isSettled ? "Finished" : "Working…"
        }
    }

    private func toolKindLabel(_ kind: AgentToolKind) -> String {
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

struct AgentRunElapsedTimeView: View {
    let phase: AgentRunPhase
    let elapsedSeconds: Int
    let startedAt: Date

    @ViewBuilder
    var body: some View {
        let elapsedTime = AgentRunElapsedTime(
            phase: phase,
            elapsedSeconds: elapsedSeconds,
            startedAt: startedAt)
        Group {
            if phase.isTerminal {
                Text(elapsedTime.formatted(at: startedAt))
            } else {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(elapsedTime.formatted(at: context.date))
                }
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
    }
}

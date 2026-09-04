// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI
import VoiceActivationCore

struct AgentRunPanelView: View {
    @Bindable var model: AgentRunPanelModel

    var body: some View {
        let cornerRadius: CGFloat = model.isMinimized ? 22 : 28
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
            backgroundGlow
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.48), accent.opacity(0.34)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    lineWidth: 1)
        }
        .padding(1)
        .frame(width: panelSize.width, height: panelSize.height)
        .animation(.snappy(duration: AgentRunPanelLayout.transitionDuration), value: model.isMinimized)
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
            Divider().opacity(0.45)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        requestCard(snapshot)
                        plan(snapshot)
                        timeline(snapshot)
                        noticeCards(snapshot)
                        failureCard(snapshot)
                        permissions(snapshot)
                        voiceInput(snapshot)
                        Color.clear.frame(height: 1).id("agent-run-bottom")
                    }
                    .padding(18)
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
            Divider().opacity(0.45)
            actions(snapshot)
        }
    }

    private func followBottom(_ proxy: ScrollViewProxy) {
        guard model.isAutoFollowing else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo("agent-run-bottom", anchor: .bottom)
        }
    }

    private func header(_ snapshot: AgentRunSnapshot) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                phaseIcon(snapshot, size: 38, symbolSize: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.providerName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(phaseLabel(snapshot.phase))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
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
                model.onAction?(.minimize(runID: snapshot.runID))
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Minimize conversation")
            .accessibilityLabel("Minimize conversation")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private func compactContent(_ snapshot: AgentRunSnapshot) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                phaseIcon(snapshot, size: 46, symbolSize: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.providerName)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
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
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 32, height: 32)
                    .background(accent.opacity(0.14), in: Circle())
                    .overlay {
                        Circle().stroke(accent.opacity(0.28), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help("Restore conversation")
            .accessibilityLabel("Restore conversation")
        }
        .padding(.horizontal, 14)
    }

    private func phaseIcon(
        _ snapshot: AgentRunSnapshot,
        size: CGFloat,
        symbolSize: CGFloat) -> some View
    {
        ZStack {
            Circle().fill(accent.opacity(0.18))
            Circle().stroke(accent.opacity(0.36), lineWidth: 1)
            Image(systemName: phaseSymbol(snapshot.phase))
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(accent)
                .symbolEffect(.variableColor.iterative, isActive: snapshot.phase == .running)
        }
        .frame(width: size, height: size)
    }

    private func requestCard(_ snapshot: AgentRunSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Request", systemImage: "quote.opening")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.8)
            Text(snapshot.prompt)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
    }

    @ViewBuilder
    private func timeline(_ snapshot: AgentRunSnapshot) -> some View {
        if snapshot.timeline.isEmpty,
           snapshot.phase == .running || snapshot.phase == .cancelling
        {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(snapshot.phase == .cancelling ? "Cancelling…" : "Waiting for output…")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
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
        VStack(alignment: .leading, spacing: 7) {
            if message.kind == .thought {
                sectionLabel("Thinking", symbol: "brain.head.profile")
            }
            AgentMarkdownView(markdown: message.text)
                .foregroundStyle(message.kind == .thought ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .tint(accent)
        }
        .padding(message.kind == .thought ? 10 : 0)
        .background {
            if message.kind == .thought {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.primary.opacity(0.035))
            }
        }
    }

    private func userMessageBlock(_ message: AgentUserMessagePresentation) -> some View {
        Text(message.text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 13))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func noticeCards(_ snapshot: AgentRunSnapshot) -> some View {
        ForEach(Array(snapshot.notices.enumerated()), id: \.offset) { _, notice in
            Label(notice, systemImage: "info.circle.fill")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func failureCard(_ snapshot: AgentRunSnapshot) -> some View {
        if case let .failed(message) = snapshot.phase {
            VStack(alignment: .leading, spacing: 5) {
                Label("Agent stopped", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                Text(message)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .textSelection(.enabled)
            }
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
        }
    }

    @ViewBuilder
    private func plan(_ snapshot: AgentRunSnapshot) -> some View {
        if !snapshot.plan.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionLabel("Plan", symbol: "list.bullet.clipboard")
                ForEach(Array(snapshot.plan.enumerated()), id: \.offset) { _, entry in
                    Label(entry.content, systemImage: planSymbol(entry.status))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(entry.status == .completed ? .secondary : .primary)
                }
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
            ? "Starting agent"
            : "\(detailCountLabel) · \(isExpanded ? "Hide" : "Show") details"
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.24)) {
                    model.toggleThinkingDetails(thinkingID: thinking.id)
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    thinkingActivityIcon(thinking)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(thinking.isWorking ? "Thinking…" : "Thinking")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
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
                        .padding(.top, 3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().opacity(0.42)
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
                .padding(.top, 9)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, thinking.isWorking ? 10 : 8)
        .background(
            thinking.hasFailedTool ? Color.red.opacity(0.075) : accent.opacity(0.075),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(thinking.hasFailedTool ? Color.red.opacity(0.75) : accent.opacity(0.78))
                .frame(width: 3)
                .padding(.vertical, 7)
        }
        .animation(.snappy(duration: 0.24), value: thinking)
    }

    @ViewBuilder
    private func thinkingActivityIcon(_ thinking: AgentThinkingPresentation) -> some View {
        ZStack {
            Circle().fill(accent.opacity(0.14))
            if thinking.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .tint(accent)
            } else {
                Image(systemName: thinking.hasFailedTool ? "exclamationmark" : "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(thinking.hasFailedTool ? .red : accent)
            }
        }
        .frame(width: 24, height: 24, alignment: .topLeading)
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
            ProgressView()
                .controlSize(.small)
                .tint(accent)
                .frame(width: 18, height: 18, alignment: .topLeading)
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
            VStack(alignment: .leading, spacing: 10) {
                Label(permission.toolTitle, systemImage: "hand.raised.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("Say “allow”, “allow all”, “deny”, or “deny all” — or choose below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    ForEach(permission.options, id: \.id) { option in
                        Button(option.label) {
                            model.selectPermission(permission, optionID: option.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(option.kind == .allowOnce || option.kind == .allowAlways
                            ? accent
                            : .red.opacity(0.82))
                        .disabled(
                            permission.isResolving
                                || model.resolvingPermissions.contains(permission.key))
                    }
                }
            }
            .padding(12)
            .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .animation(.snappy(duration: 0.2), value: snapshot.permissions.map(\.id))
    }

    @ViewBuilder
    private func voiceInput(_ snapshot: AgentRunSnapshot) -> some View {
        if !snapshot.phase.isTerminal {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.voiceInput.isEmpty ? "Listening for you…" : snapshot.voiceInput)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(snapshot.voiceInput.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Speak a follow-up, or say “stop” to end the conversation.")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(11)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func actions(_ snapshot: AgentRunSnapshot) -> some View {
        HStack {
            if snapshot.phase == .running {
                Button("Stop turn", systemImage: "stop.circle.fill") {
                    model.onAction?(.cancel(runID: snapshot.runID))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red.opacity(0.84))
            } else if snapshot.phase == .cancelling {
                Button("Cancelling…", systemImage: "clock") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            }
            Spacer()
            if !snapshot.phase.isTerminal {
                Button("End conversation", systemImage: "rectangle.portrait.and.arrow.right") {
                    model.onAction?(.endConversation(runID: snapshot.runID))
                }
                .buttonStyle(.bordered)
            } else {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    model.onAction?(.delete(runID: snapshot.runID))
                }
                .buttonStyle(.bordered)
                Button("Copy output", systemImage: "doc.on.doc") {
                    model.onAction?(.copy(runID: snapshot.runID))
                }
                Button("Close", systemImage: "xmark") {
                    model.onAction?(.close(runID: snapshot.runID))
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func sectionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.8)
    }

    private var accent: Color {
        model.snapshot?.accent.swiftUIColor ?? .blue
    }

    private var panelSize: CGSize {
        model.isMinimized
            ? AgentRunPanelLayout.compactSize
            : AgentRunPanelLayout.expandedSize
    }

    private var backgroundGlow: some View {
        LinearGradient(
            colors: [accent.opacity(0.18), .clear, accent.opacity(0.07)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
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
        case .listening: "Listening for follow-up"
        case .running: "Running"
        case .cancelling: "Cancelling"
        case let .completed(reason): reason == .cancelled ? "Cancelled" : "Completed"
        case .failed: "Failed"
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

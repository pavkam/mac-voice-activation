import SwiftUI
import VoiceActivationCore

struct AgentRunPanelView: View {
    @Bindable var model: AgentRunPanelModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
            backgroundGlow
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.48), accent.opacity(0.34)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    lineWidth: 1)
        }
        .padding(1)
        .frame(width: 620, height: 420)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = model.snapshot {
            VStack(spacing: 0) {
                header(snapshot)
                Divider().opacity(0.45)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            requestCard(snapshot)
                            noticeCards(snapshot)
                            plan(snapshot)
                            timeline(snapshot)
                            permissions(snapshot)
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
                    } action: { _, distance in
                        model.updateAutoFollowing(distanceFromBottom: distance)
                    }
                    .onChange(of: snapshot.timeline) {
                        guard model.isAutoFollowing else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo("agent-run-bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: snapshot.permissions) {
                        guard model.isAutoFollowing else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo("agent-run-bottom", anchor: .bottom)
                        }
                    }
                }
                Divider().opacity(0.45)
                actions(snapshot)
            }
        }
    }

    private func header(_ snapshot: AgentRunSnapshot) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(accent.opacity(0.18))
                Circle().stroke(accent.opacity(0.36), lineWidth: 1)
                Image(systemName: phaseSymbol(snapshot.phase))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                    .symbolEffect(.variableColor.iterative, isActive: snapshot.phase == .running)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.providerName)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(phaseLabel(snapshot.phase))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(elapsed(snapshot.elapsedSeconds))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
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
                case let .tool(tool):
                    toolCard(tool)
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

    private func toolCard(_ tool: AgentToolPresentation) -> some View {
        let isExpanded = model.isToolExpanded(toolID: tool.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.24)) {
                    model.toggleToolDetails(toolID: tool.id)
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    toolActivityIcon(tool)

                    Text(toolSummary(tool))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(tool.status == .failed ? .red : .primary)
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
                VStack(alignment: .leading, spacing: 7) {
                    Divider().opacity(0.42)
                    if let kind = tool.kind {
                        Text(toolKindLabel(kind))
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.7)
                    }
                    Text(tool.title)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.top, 9)
                .padding(.leading, 28)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, tool.status.isFinished ? 8 : 10)
        .background(
            tool.status == .failed ? Color.red.opacity(0.075) : accent.opacity(0.065),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(tool.status == .failed ? Color.red.opacity(0.75) : accent.opacity(0.72))
                .frame(width: 2)
                .padding(.vertical, 7)
        }
        .animation(.snappy(duration: 0.24), value: tool.status)
    }

    @ViewBuilder
    private func toolActivityIcon(_ tool: AgentToolPresentation) -> some View {
        if tool.status.isWorking {
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

    private func actions(_ snapshot: AgentRunSnapshot) -> some View {
        HStack {
            if snapshot.phase == .running {
                Button("Cancel", systemImage: "xmark.circle.fill") {
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
            if snapshot.phase.isTerminal {
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

    private var backgroundGlow: some View {
        LinearGradient(
            colors: [accent.opacity(0.18), .clear, accent.opacity(0.07)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }

    private func phaseLabel(_ phase: AgentRunPhase) -> String {
        switch phase {
        case .running: "Running"
        case .cancelling: "Cancelling"
        case let .completed(reason): reason == .cancelled ? "Cancelled" : "Completed"
        case .failed: "Failed"
        }
    }

    private func phaseSymbol(_ phase: AgentRunPhase) -> String {
        switch phase {
        case .running: "sparkles"
        case .cancelling: "clock.arrow.circlepath"
        case let .completed(reason): reason == .cancelled ? "xmark" : "checkmark"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func elapsed(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
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
        case .pending, nil: "circle.dotted"
        }
    }

    private func toolSummary(_ tool: AgentToolPresentation) -> String {
        switch tool.status {
        case .failed:
            tool.kind.map { "\(toolKindLabel($0)) failed" } ?? "Tool failed"
        case .completed:
            tool.kind.map { "\(toolKindLabel($0)) complete" } ?? "Completed"
        case .pending, .inProgress, nil:
            "Working…"
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

private extension AgentToolCallStatus? {
    var isWorking: Bool {
        self == nil || self == .pending || self == .inProgress
    }

    var isFinished: Bool {
        self == .completed || self == .failed
    }
}

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
                            response(snapshot)
                            plan(snapshot)
                            tools(snapshot)
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
                    .onChange(of: snapshot.output) {
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
    private func response(_ snapshot: AgentRunSnapshot) -> some View {
        if !snapshot.output.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionLabel("Live output", symbol: "text.alignleft")
                Text(snapshot.output)
                    .font(.system(size: 13, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        } else if snapshot.phase == .running || snapshot.phase == .cancelling {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(snapshot.phase == .cancelling ? "Cancelling…" : "Waiting for output…")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
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

    @ViewBuilder
    private func tools(_ snapshot: AgentRunSnapshot) -> some View {
        if !snapshot.tools.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionLabel("Tools", symbol: "hammer.fill")
                ForEach(snapshot.tools) { tool in
                    HStack(spacing: 8) {
                        Image(systemName: toolSymbol(tool))
                            .foregroundStyle(tool.status == .failed ? .red : accent)
                        Text(tool.title)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                        Spacer()
                        Text(tool.status?.rawValue.replacingOccurrences(of: "_", with: " ") ?? "")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
        }
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
}

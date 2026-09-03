import AppKit
import SwiftUI
import VoiceActivationCore

struct MenuContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            statusHeader

            if !model.lastTranscript.isEmpty {
                lastCommand
            }

            if let snapshot = model.agentRunSnapshot {
                agentRunControls(snapshot)
            }

            profileList

            if model.state == .capturing {
                cancelButton
            }

            footer
        }
        .frame(width: 356)
        .background(panelBackground)
    }

    private var statusHeader: some View {
        let presentation = MenuStatusPresentation.make(
            state: model.state,
            enabledProfileCount: enabledProfileCount)

        return HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(headerAccent.opacity(0.16))

                Circle()
                    .stroke(headerAccent.opacity(0.28), lineWidth: 1)

                Image(systemName: presentation.symbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(presentation.isError ? .red : headerAccent)
                    .symbolEffect(.variableColor.iterative, isActive: model.state == .capturing)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))

                Text(presentation.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Circle()
                .fill(presentation.isError ? Color.red : headerAccent)
                .frame(width: 8, height: 8)
                .shadow(
                    color: (presentation.isError ? Color.red : headerAccent).opacity(0.55),
                    radius: 4)
        }
        .padding(.horizontal, 18)
        .padding(.top, 17)
        .padding(.bottom, 14)
    }

    private var lastCommand: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Last command", systemImage: "text.quote")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.8)

            Text(MenuTranscriptSummary.format(model.lastTranscript, maximumLength: 92))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var profileList: some View {
        let listeningControl = MenuListeningControlPresentation.make(
            isListening: model.passiveEnabled)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Wake profiles")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.8)

                Spacer()

                Button {
                    model.togglePassiveListening()
                } label: {
                    Label(listeningControl.title, systemImage: listeningControl.symbolName)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(model.passiveEnabled ? Color.secondary : headerAccent)
                        .background(.primary.opacity(0.055), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.white.opacity(0.08), lineWidth: 0.75)
                        }
                }
                .buttonStyle(.plain)
                .help("\(listeningControl.title) wake phrase listening")
                .accessibilityLabel("\(listeningControl.title) wake phrase listening")
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(model.activeWakeProfiles) { profile in
                        MenuProfileRow(profile: profile) {
                            model.setWakeProfileEnabled(profile.id, enabled: !profile.isEnabled)
                        }
                    }
                }
            }
            .frame(height: MenuProfileListLayout.height(
                profileCount: model.activeWakeProfiles.count))
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private func agentRunControls(_ snapshot: AgentRunSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(snapshot.providerName, systemImage: "sparkles")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(snapshot.accent.swiftUIColor)
                Spacer()
                Text(agentRunPhaseLabel(snapshot.phase))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    model.showAgentRun()
                } label: {
                    Label("Show agent run", systemImage: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if snapshot.phase == .running {
                    Button {
                        model.cancelAgentRun(runID: snapshot.runID)
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red.opacity(0.84))
                } else if snapshot.phase == .cancelling {
                    Button("Cancelling…") {}
                        .buttonStyle(.bordered)
                        .disabled(true)
                }
            }
        }
        .padding(12)
        .background(snapshot.accent.swiftUIColor.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(snapshot.accent.swiftUIColor.opacity(0.16), lineWidth: 0.75)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func agentRunPhaseLabel(_ phase: AgentRunPhase) -> String {
        switch phase {
        case .running: "Running"
        case .cancelling: "Cancelling"
        case let .completed(reason): reason == .cancelled ? "Cancelled" : "Completed"
        case .failed: "Failed"
        }
    }

    private var cancelButton: some View {
        Button {
            model.cancelCapture()
        } label: {
            Label("Cancel recording", systemImage: "xmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red.opacity(0.86))
        .keyboardShortcut(.cancelAction)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
                SettingsWindowPresenter.live.open {
                    openWindow(id: SettingsWindowPresenter.windowID)
                }
            } label: {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .keyboardShortcut(",")

            Spacer()

            Button {
                model.shutdown()
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
        .font(.system(size: 12, weight: .medium))
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(.primary.opacity(0.035))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var panelBackground: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            LinearGradient(
                colors: [
                    headerAccent.opacity(0.11),
                    .clear,
                    headerAccent.opacity(0.04),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
        }
    }

    private var enabledProfileCount: Int {
        model.activeWakeProfiles.count(where: \.isEnabled)
    }

    private var headerAccent: Color {
        model.activeWakeProfiles.first(where: \.isEnabled)?.accent.swiftUIColor ?? .secondary
    }
}

private struct MenuProfileRow: View {
    let profile: WakeProfile
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(profile.accent.swiftUIColor.opacity(profile.isEnabled ? 0.18 : 0.07))

                    Image(systemName: profile.isEnabled ? "waveform" : "waveform.slash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(
                            profile.isEnabled ? profile.accent.swiftUIColor : .secondary)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("“\(profile.wakePhrase)”")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text(profileDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: profile.isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(
                        profile.isEnabled
                            ? profile.accent.swiftUIColor
                            : Color.secondary.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(
                isHovering ? Color.primary.opacity(0.075) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.white.opacity(isHovering ? 0.14 : 0.07), lineWidth: 0.75)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Listen for \(profile.wakePhrase)")
        .accessibilityValue(profile.isEnabled ? "Enabled" : "Disabled")
    }

    private var profileDetail: String {
        if let hotKey = profile.pushToTalkHotKey {
            "\(hotKey.displayName)  ·  Hold to talk"
        } else {
            profile.isEnabled ? "Wake phrase active" : "Wake phrase paused"
        }
    }
}

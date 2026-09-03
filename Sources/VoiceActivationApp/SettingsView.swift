import SwiftUI
import VoiceActivationCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var launchAtLogin = LaunchAtLoginSetting()
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    voiceSection
                    conversationSection
                    startupSection
                    privacyNote
                }
                .padding(28)
            }
            .disabled(model.isSavingSettings)

            Divider()
            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(.bar)
        }
        .frame(width: 720, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.wakeProfiles) { saved = false }
        .onChange(of: model.localeID) { saved = false }
        .onChange(of: model.readsAgentRepliesAloud) { saved = false }
        .onChange(of: model.playsAgentWorkingSound) { saved = false }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VoiceActivationMark(tint: headerTint)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("Voice Activation")
                    .font(.title2.weight(.semibold))
                Text("Turn speech into a command, hands free or on demand.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(model.state.label, systemImage: StatusIcon.symbol(for: model.state))
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
    }

    private var startupSection: some View {
        SettingsCard(
            title: "Startup",
            subtitle: "Keep Voice Activation ready after you sign in.",
            systemImage: "power")
        {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Launch at Login")
                        .fontWeight(.medium)
                    Text("Managed by macOS in System Settings › General › Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }))
                    .labelsHidden()
            }

            if let error = launchAtLogin.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var conversationSection: some View {
        SettingsCard(
            title: "Agent conversation",
            subtitle: "Keep longer agent sessions audible without making them noisy.",
            systemImage: "bubble.left.and.waveform.fill")
        {
            settingToggle(
                title: "Read replies aloud",
                detail: "Uses the selected macOS system voice after each completed response.",
                isOn: $model.readsAgentRepliesAloud)

            Divider()

            settingToggle(
                title: "Working pulse",
                detail: "Plays a quiet cue during longer pauses while the agent is thinking or using tools.",
                isOn: $model.playsAgentWorkingSound)
        }
    }

    private var voiceSection: some View {
        SettingsCard(
            title: "Voice trigger",
            subtitle: "Choose what starts listening and how speech is recognized.",
            systemImage: "ear.badge.waveform")
        {
            settingsField("Speech locale", hint: "en-US", text: $model.localeID)
                .frame(width: 170)

            Divider()

            VStack(spacing: 12) {
                ForEach($model.wakeProfiles) { $profile in
                    wakeProfileEditor(profile: $profile)
                }

                Button {
                    model.wakeProfiles.append(WakeProfileDraft(
                        wakePhrase: "",
                        urlTemplate: "https://www.google.com/search?q={urlText}",
                        accent: nextAccent))
                } label: {
                    Label("Add wake profile", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Always listen for wake phrases")
                        .fontWeight(.medium)
                    Text("Recognition stays on-device while passive listening is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { model.passiveEnabled },
                        set: { model.setPassiveEnabled($0) }))
                    .labelsHidden()
            }
        }
    }

    private var privacyNote: some View {
        Label {
            Text("Push to talk may use Apple’s speech service when on-device recognition is unavailable.")
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        HStack {
            if let error = model.settingsError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if saved {
                Label("Settings saved", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            Spacer()

            Button("Save Settings") {
                Task { @MainActor in
                    saved = await SettingsSaveHandler.perform(
                        save: model.saveSettings,
                        close: {
                            dismissWindow(id: SettingsWindowPresenter.windowID)
                        })
                }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .disabled(model.isSavingSettings)
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .failed:
            .red
        case .capturing, .executing:
            .orange
        case .listening:
            .green
        case .disabled:
            .secondary
        }
    }

    private var headerTint: Color {
        model.wakeProfiles.first(where: \WakeProfileDraft.isEnabled)?.accent.swiftUIColor
            ?? .cyan
    }

    private func settingsField(
        _ title: String,
        hint: String,
        text: Binding<String>,
        monospaced: Bool = false) -> some View
    {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(hint, text: text)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func settingToggle(
        title: String,
        detail: String,
        isOn: Binding<Bool>) -> some View
    {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }

    private func templateToken(_ value: String) -> some View {
        Text(value)
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }

    private func wakeProfileEditor(profile: Binding<WakeProfileDraft>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(profile.wrappedValue.accent.swiftUIColor)
                    .frame(width: 12, height: 12)
                    .shadow(color: profile.wrappedValue.accent.swiftUIColor.opacity(0.5), radius: 4)

                TextField("Wake phrase", text: profile.wakePhrase)
                    .textFieldStyle(.roundedBorder)

                Picker("Color", selection: profile.accent) {
                    ForEach(WakeProfileAccent.allCases, id: \.self) { accent in
                        Label {
                            Text(accent.displayName)
                        } icon: {
                            Image(nsImage: WakeProfileAccentSwatch.image(for: accent))
                                .renderingMode(.original)
                        }
                            .tag(accent)
                    }
                }
                .labelsHidden()
                .frame(width: 110)

                Button(role: .destructive) {
                    model.wakeProfiles.removeAll { $0.id == profile.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(model.wakeProfiles.count == 1)
                .help("Remove wake profile")
            }

            Picker(
                "Target",
                selection: Binding(
                    get: { profile.wrappedValue.targetKind },
                    set: { profile.wrappedValue.selectTarget($0) }))
            {
                Text("Command").tag(WakeProfileTargetKind.command)
                Text("Agent").tag(WakeProfileTargetKind.agent)
            }
            .pickerStyle(.segmented)

            switch profile.wrappedValue.targetKind {
            case .command:
                commandEditor(profile: profile)
            case .agent:
                AgentHarnessSettingsView(profile: profile)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Push to talk")
                        .fontWeight(.medium)
                    Text("Hold this shortcut to run this voice profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HotKeyRecorderView(
                    hotKey: profile.wrappedValue.pushToTalkHotKey,
                    onChange: {
                        model.setPushToTalkHotKey($0, for: profile.wrappedValue.id)
                    },
                    onClear: {
                        model.setPushToTalkHotKey(nil, for: profile.wrappedValue.id)
                    },
                    onRecordingChange: model.setPushToTalkShortcutRecording)
            }
        }
        .padding(13)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func commandEditor(profile: Binding<WakeProfileDraft>) -> some View {
        settingsField(
            "Executable",
            hint: "/usr/bin/open",
            text: profile.executablePath,
            monospaced: true)

        argumentEditor(
            "Argument templates",
            hint: "Argument containing {text} or {urlText}",
            arguments: profile.commandArguments)

        HStack(spacing: 6) {
            templateToken("{urlText}")
            Text("inserts URL-encoded speech")
            Text("•")
            templateToken("{text}")
            Text("inserts literal speech")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func argumentEditor(
        _ title: String,
        hint: String,
        arguments: Binding<ArgumentDraftCollection>) -> some View
    {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ForEach(arguments.rows) { argument in
                HStack(spacing: 6) {
                    TextField(hint, text: argument.value)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)

                    Button(role: .destructive) {
                        arguments.wrappedValue.remove(id: argument.wrappedValue.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove argument")
                }
            }

            Button {
                arguments.wrappedValue.append()
            } label: {
                Label("Add argument", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private var nextAccent: WakeProfileAccent {
        let accents = WakeProfileAccent.allCases
        return accents[model.wakeProfiles.count % accents.count]
    }
}

extension WakeProfileAccent {
    var displayName: String { rawValue.capitalized }

    var swiftUIColor: Color {
        switch self {
        case .cyan: .cyan
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .orange: .orange
        case .green: .green
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.separator.opacity(0.65), lineWidth: 1)
        }
    }
}

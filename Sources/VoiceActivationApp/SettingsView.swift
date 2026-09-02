import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    voiceSection
                    commandSection
                    privacyNote
                }
                .padding(28)
            }

            Divider()
            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(.bar)
        }
        .frame(width: 680, height: 610)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.wakePhrase) { saved = false }
        .onChange(of: model.localeID) { saved = false }
        .onChange(of: model.executablePath) { saved = false }
        .onChange(of: model.argumentTemplatesText) { saved = false }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 48, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)

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

    private var voiceSection: some View {
        SettingsCard(
            title: "Voice trigger",
            subtitle: "Choose what starts listening and how speech is recognized.",
            systemImage: "ear.badge.waveform")
        {
            HStack(alignment: .top, spacing: 14) {
                settingsField("Wake phrase", hint: "computer", text: $model.wakePhrase)
                settingsField("Speech locale", hint: "en-US", text: $model.localeID)
                    .frame(width: 170)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Always listen for the wake phrase")
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

            HStack {
                Label("Push to talk", systemImage: "keyboard")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("⌃⌥Space")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private var commandSection: some View {
        SettingsCard(
            title: "Command",
            subtitle: "The executable runs once a phrase has been captured.",
            systemImage: "terminal")
        {
            settingsField(
                "Executable",
                hint: "/usr/bin/open",
                text: $model.executablePath,
                monospaced: true)

            VStack(alignment: .leading, spacing: 7) {
                Text("Arguments")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                TextEditor(text: $model.argumentTemplatesText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(minHeight: 82)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator, lineWidth: 1)
                    }

                HStack(spacing: 6) {
                    templateToken("{text}")
                    Text("literal speech")
                    Text("•")
                    templateToken("{urlText}")
                    Text("URL-encoded speech")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
                saved = model.saveSettings()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
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

    private func templateToken(_ value: String) -> some View {
        Text(value)
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
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

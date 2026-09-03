import AppKit
import SwiftUI
import VoiceActivationCore

struct AgentHarnessSettingsView: View {
    @Binding var profile: WakeProfileDraft
    @State private var executableLocator = AgentExecutableLocator()

    var body: some View {
        let draft = profile.agentHarness
        let preset = draft.preset
        let tint = profile.accent.swiftUIColor
        let executableLocation = executableLocator.resolve(
            executable: draft.executablePath)
        let hasResolvedPath = executableLocation != nil
            && draft.executablePath.hasPrefix("/")

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 13) {
                    AgentProviderMark(preset: preset, tint: tint)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(draft.displayName.nilIfBlank ?? preset.displayName)
                            .font(.system(.headline, design: .rounded).weight(.semibold))
                        Text(preset.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    executableBadge(
                        isReady: hasResolvedPath,
                        wasDetected: executableLocation != nil,
                        hasPath: !draft.executablePath.isEmpty)
                }

                HStack(spacing: 7) {
                    ForEach(AgentHarnessPreset.allCases, id: \.self) { option in
                        Button {
                            withAnimation(.snappy(duration: 0.22)) {
                                profile.agentHarness.selectPreset(option)
                            }
                        } label: {
                            Label(option.displayName, systemImage: option.systemImage)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AgentProviderButtonStyle(
                            isSelected: option == preset,
                            tint: tint))
                    }
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.12), .primary.opacity(0.025)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(tint.opacity(0.22), lineWidth: 1)
            }

            HStack(alignment: .bottom, spacing: 12) {
                settingsField(
                    "Display name",
                    hint: "Local agent",
                    text: $profile.agentHarness.displayName)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Permission policy")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker(
                        "Permission policy",
                        selection: $profile.agentHarness.permissionPolicy)
                    {
                        ForEach(AgentPermissionPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .labelsHidden()
                }
                .frame(width: 180)
            }

            executableField(
                location: executableLocation,
                hasResolvedPath: hasResolvedPath,
                tint: tint)
            workingDirectoryField
            advancedArguments(draft: draft)
        }
    }

    private func settingsField(
        _ title: String,
        hint: String,
        text: Binding<String>) -> some View
    {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(hint, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func executableField(
        location: AgentExecutableLocation?,
        hasResolvedPath: Bool,
        tint: Color) -> some View
    {
        let draft = profile.agentHarness

        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Executable")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(executableSourceDetail(location))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(hasResolvedPath ? Color.green : Color.orange)
            }

            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(hasResolvedPath ? tint : .secondary)
                    .frame(width: 18)

                TextField(
                    draft.preset.executableHint,
                    text: $profile.agentHarness.executablePath)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .onSubmit {
                        _ = profile.agentHarness.detectExecutable()
                    }

                Button {
                    _ = profile.agentHarness.detectExecutable()
                } label: {
                    Label("Detect", systemImage: "scope")
                }
                .buttonStyle(.borderless)
                .disabled(draft.preset == .custom && draft.executablePath.isEmpty)
                .help("Resolve this executable from PATH and known install locations")

                Divider()
                    .frame(height: 18)

                Button(action: chooseExecutable) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Choose executable")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        hasResolvedPath ? tint.opacity(0.28) : Color.orange.opacity(0.34),
                        lineWidth: 1)
            }

            Text(executableGuidance(draft: draft, location: location))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var workingDirectoryField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Working folder")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                TextField(
                    "/absolute/path/to/project",
                    text: $profile.agentHarness.workingDirectory)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)

                Button(action: chooseWorkingDirectory) {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Choose working folder")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.55), lineWidth: 1)
            }
        }
    }

    private func advancedArguments(draft: AgentHarnessDraft) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                Text("Adapter arguments")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                ForEach($profile.agentHarness.argumentDrafts.rows) { argument in
                    HStack(spacing: 6) {
                        TextField("Argument", text: argument.value)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)

                        Button(role: .destructive) {
                            profile.agentHarness.argumentDrafts.remove(
                                id: argument.wrappedValue.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove argument")
                    }
                }

                Button {
                    profile.agentHarness.argumentDrafts.append()
                } label: {
                    Label("Add argument", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 9)
        } label: {
            HStack {
                Label("Advanced launch options", systemImage: "slider.horizontal.3")
                    .fontWeight(.medium)
                Spacer()
                Text("\(draft.arguments.count) arguments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.secondary)
    }

    private func executableBadge(
        isReady: Bool,
        wasDetected: Bool,
        hasPath: Bool) -> some View
    {
        let title = if isReady {
            "Ready"
        } else if wasDetected {
            "Detected"
        } else if hasPath {
            "Not found"
        } else {
            "Needs setup"
        }
        return Label(
            title,
            systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isReady ? Color.green : Color.orange)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                (isReady ? Color.green : Color.orange).opacity(0.11),
                in: Capsule())
    }

    private func executableSourceDetail(_ location: AgentExecutableLocation?) -> String {
        guard let location else { return "Not detected" }
        switch location.source {
        case .environmentPath:
            return "Found in PATH"
        case .knownLocation:
            return "Found automatically"
        case .nodeVersionManager:
            return "Found via NVM"
        case .explicitPath:
            return "Selected executable"
        }
    }

    private func executableGuidance(
        draft: AgentHarnessDraft,
        location: AgentExecutableLocation?) -> String
    {
        if let location {
            if !draft.executablePath.hasPrefix("/") {
                return "Found \(location.path). Click Detect to use the absolute path."
            }
            return location.path
        }
        if draft.executablePath.isEmpty {
            return draft.preset == .custom
                ? "Enter a command name to detect it from PATH, or choose an executable."
                : "Click Detect to search PATH and common macOS install locations."
        }
        return "That executable is not available. Check the name or choose it directly."
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose ACP executable"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        let currentPath = profile.agentHarness.executablePath
        if currentPath.hasPrefix("/") {
            panel.directoryURL = URL(fileURLWithPath: currentPath).deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        profile.agentHarness.executablePath = path
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose agent working folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        let currentPath = profile.agentHarness.workingDirectory
        if currentPath.hasPrefix("/") {
            panel.directoryURL = URL(fileURLWithPath: currentPath)
        }

        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        profile.agentHarness.workingDirectory = path
    }
}

private extension AgentHarnessPreset {
    var displayName: String {
        switch self {
        case .cursor: "Cursor"
        case .codex: "Codex"
        case .claude: "Claude"
        case .custom: "Custom"
        }
    }

    var subtitle: String {
        switch self {
        case .cursor: "Native Agent Client Protocol connection"
        case .codex: "Codex through a pinned ACP adapter"
        case .claude: "Claude through a pinned ACP adapter"
        case .custom: "Your own Agent Client Protocol process"
        }
    }

    var systemImage: String {
        switch self {
        case .cursor: "cursorarrow.rays"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "sparkles"
        case .custom: "cpu"
        }
    }

    var executableHint: String {
        switch self {
        case .cursor: "cursor-agent or /absolute/path"
        case .codex, .claude: "npx or /absolute/path/to/npx"
        case .custom: "Command name or /absolute/path"
        }
    }
}

private extension AgentPermissionPolicy {
    var displayName: String {
        switch self {
        case .ask: "Ask"
        case .allowOnce: "Allow once"
        case .reject: "Reject"
        }
    }
}

private struct AgentProviderMark: View {
    let preset: AgentHarnessPreset
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(
                    colors: [tint.opacity(0.95), tint.opacity(0.52)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))

            Image(systemName: preset.systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 44, height: 44)
        .shadow(color: tint.opacity(0.28), radius: 7, y: 3)
        .accessibilityHidden(true)
    }
}

private struct AgentProviderButtonStyle: ButtonStyle {
    let isSelected: Bool
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(isSelected ? tint : Color.primary.opacity(0.78))
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.16) : Color.primary.opacity(0.045))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected ? tint.opacity(0.46) : Color.primary.opacity(0.07),
                        lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

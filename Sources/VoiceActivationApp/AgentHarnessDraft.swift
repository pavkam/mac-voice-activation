import Foundation
import VoiceActivationCore

struct AgentHarnessDraft: Equatable {
    var preset: AgentHarnessPreset
    var displayName: String
    var executablePath: String
    var arguments: [String]
    var workingDirectory: String
    var permissionPolicy: AgentPermissionPolicy

    init(
        preset: AgentHarnessPreset,
        displayName: String,
        executablePath: String,
        arguments: [String],
        workingDirectory: String,
        permissionPolicy: AgentPermissionPolicy)
    {
        self.preset = preset
        self.displayName = displayName
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.permissionPolicy = permissionPolicy
    }

    init(configuration: AgentHarnessConfiguration) {
        preset = configuration.preset
        displayName = configuration.displayName
        executablePath = configuration.executablePath
        arguments = configuration.arguments
        workingDirectory = configuration.workingDirectory
        permissionPolicy = configuration.permissionPolicy
    }

    static func empty(workingDirectory: String) -> AgentHarnessDraft {
        AgentHarnessDraft(
            preset: .custom,
            displayName: "",
            executablePath: "",
            arguments: [],
            workingDirectory: workingDirectory,
            permissionPolicy: .ask)
    }

    mutating func selectPreset(
        _ selectedPreset: AgentHarnessPreset,
        locator: AgentExecutableLocator = AgentExecutableLocator())
    {
        guard selectedPreset != preset else { return }
        preset = selectedPreset

        switch selectedPreset {
        case .cursor:
            displayName = "Cursor"
            executablePath = locator.locate(executable: "cursor-agent") ?? ""
            arguments = ["acp"]
        case .codex:
            displayName = "Codex"
            executablePath = locator.locate(executable: "npx") ?? ""
            arguments = ["-y", "@agentclientprotocol/codex-acp@1.8.0"]
        case .claude:
            displayName = "Claude"
            executablePath = locator.locate(executable: "npx") ?? ""
            arguments = ["-y", "@agentclientprotocol/claude-agent-acp@0.73.0"]
        case .custom:
            break
        }
    }

    func validatedConfiguration() throws -> AgentHarnessConfiguration {
        try AgentHarnessConfiguration(
            preset: preset,
            displayName: displayName,
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            permissionPolicy: permissionPolicy)
    }
}

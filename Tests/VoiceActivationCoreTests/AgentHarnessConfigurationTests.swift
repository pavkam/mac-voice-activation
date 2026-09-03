import Foundation
import Testing
@testable import VoiceActivationCore

struct AgentHarnessConfigurationTests {
    @Test func init_WhenExecutableIsRelative_RejectsAgentConfiguration() {
        #expect(throws: AgentHarnessConfiguration.ValidationError.executableMustBeAbsolute) {
            try AgentHarnessConfiguration(
                preset: .custom,
                displayName: "Local agent",
                executablePath: "agent",
                arguments: ["acp"],
                workingDirectory: "/tmp",
                permissionPolicy: .ask)
        }
    }

    @Test func init_WhenWorkingDirectoryIsRelative_RejectsAgentConfiguration() {
        #expect(throws: AgentHarnessConfiguration.ValidationError.workingDirectoryMustBeAbsolute) {
            try AgentHarnessConfiguration(
                preset: .custom,
                displayName: "Local agent",
                executablePath: "/usr/local/bin/agent",
                arguments: ["acp"],
                workingDirectory: "workspace",
                permissionPolicy: .ask)
        }
    }

    @Test func coding_WhenAgentConfigurationIsValid_RoundTripsEveryField() throws {
        let configuration = try AgentHarnessConfiguration(
            preset: .codex,
            displayName: "Codex ACP",
            executablePath: "/opt/homebrew/bin/npx",
            arguments: ["-y", "@agentclientprotocol/codex-acp@1.8.0"],
            workingDirectory: "/Users/alex/Development/voice-activation",
            permissionPolicy: .allowOnce)

        let decoded = try JSONDecoder().decode(
            AgentHarnessConfiguration.self,
            from: JSONEncoder().encode(configuration))

        #expect(decoded == configuration)
    }
}

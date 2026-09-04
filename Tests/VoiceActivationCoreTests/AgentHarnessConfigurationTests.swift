import Foundation
import Testing
@testable import VoiceActivationCore

struct AgentHarnessConfigurationTests {
    @Test func decoding_WhenDisplayNameIsBlank_RejectsAgentConfiguration() throws {
        let data = try #require("""
        {"preset":"custom","displayName":"  ","executablePath":"/usr/local/bin/agent","arguments":["acp"],"workingDirectory":"/tmp","permissionPolicy":"ask"}
        """.data(using: .utf8))

        #expect(throws: AgentHarnessConfiguration.ValidationError.displayNameRequired) {
            try JSONDecoder().decode(AgentHarnessConfiguration.self, from: data)
        }
    }

    @Test func decoding_WhenExecutableIsRelative_RejectsAgentConfiguration() throws {
        let data = try #require("""
        {"preset":"custom","displayName":"Local agent","executablePath":"agent","arguments":["acp"],"workingDirectory":"/tmp","permissionPolicy":"ask"}
        """.data(using: .utf8))

        #expect(throws: AgentHarnessConfiguration.ValidationError.executableMustBeAbsolute) {
            try JSONDecoder().decode(AgentHarnessConfiguration.self, from: data)
        }
    }

    @Test func decoding_WhenWorkingDirectoryIsRelative_RejectsAgentConfiguration() throws {
        let data = try #require("""
        {"preset":"custom","displayName":"Local agent","executablePath":"/usr/local/bin/agent","arguments":["acp"],"workingDirectory":"workspace","permissionPolicy":"ask"}
        """.data(using: .utf8))

        #expect(throws: AgentHarnessConfiguration.ValidationError.workingDirectoryMustBeAbsolute) {
            try JSONDecoder().decode(AgentHarnessConfiguration.self, from: data)
        }
    }

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
            permissionPolicy: .allowAlways,
            systemPrompt: "Be concise and lead with the outcome.")

        let decoded = try JSONDecoder().decode(
            AgentHarnessConfiguration.self,
            from: JSONEncoder().encode(configuration))

        #expect(decoded == configuration)
    }

    @Test func decoding_WhenLegacyConfigurationHasNoSystemPrompt_DefaultsToEmpty() throws {
        let data = try #require("""
        {"preset":"custom","displayName":"Local agent","executablePath":"/usr/local/bin/agent","arguments":["acp"],"workingDirectory":"/tmp","permissionPolicy":"ask"}
        """.data(using: .utf8))

        let configuration = try JSONDecoder().decode(AgentHarnessConfiguration.self, from: data)

        #expect(configuration.systemPrompt.isEmpty)
    }

    @Test func init_WhenSystemPromptExceedsLimit_RejectsAgentConfiguration() {
        #expect(throws: AgentHarnessConfiguration.ValidationError.systemPromptTooLarge(
            maximumBytes: AgentHarnessConfiguration.maximumSystemPromptBytes)) {
            try AgentHarnessConfiguration(
                preset: .custom,
                displayName: "Local agent",
                executablePath: "/usr/local/bin/agent",
                arguments: ["acp"],
                workingDirectory: "/tmp",
                permissionPolicy: .ask,
                systemPrompt: String(
                    repeating: "a",
                    count: AgentHarnessConfiguration.maximumSystemPromptBytes + 1))
        }
    }
}

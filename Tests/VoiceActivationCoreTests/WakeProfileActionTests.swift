import Foundation
import Testing
@testable import VoiceActivationCore

struct WakeProfileActionTests {
    @Test func coding_WhenActionIsCommand_RoundTripsTemplate() throws {
        let action = WakeProfileAction.command(try CommandTemplate(
            executablePath: "/usr/bin/open",
            argumentTemplates: ["https://example.com?q={urlText}"]))

        let decoded = try JSONDecoder().decode(
            WakeProfileAction.self,
            from: JSONEncoder().encode(action))

        #expect(decoded == action)
    }

    @Test func coding_WhenActionIsAgent_RoundTripsHarness() throws {
        let action = WakeProfileAction.agent(try AgentHarnessConfiguration(
            preset: .claude,
            displayName: "Claude ACP",
            executablePath: "/opt/homebrew/bin/npx",
            arguments: ["-y", "@agentclientprotocol/claude-agent-acp@0.73.0"],
            workingDirectory: "/Users/alex/Development/voice-activation",
            permissionPolicy: .reject))

        let decoded = try JSONDecoder().decode(
            WakeProfileAction.self,
            from: JSONEncoder().encode(action))

        #expect(decoded == action)
    }
}

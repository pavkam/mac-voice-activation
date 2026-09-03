import Foundation
import Testing
@testable import VoiceActivationApp
import VoiceActivationCore

struct WakeProfileDraftTests {
    @Test func validatedProfile_WhenDraftUsesCommand_RoundTripsCommandAction() throws {
        let id = try #require(UUID(uuidString: "166BED99-7C1C-4E01-A85E-7F672301973E"))
        let hotKey = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        let profile = try WakeProfile(
            id: id,
            wakePhrase: "computer",
            executablePath: "/usr/bin/printf",
            argumentTemplates: ["--format", "%s", "{text}", "two words", ""],
            accent: .orange,
            isEnabled: false,
            pushToTalkHotKey: hotKey)

        let roundTripped = try WakeProfileDraft(profile: profile).validatedProfile()

        #expect(roundTripped == profile)
    }

    @Test func validatedProfile_WhenDraftUsesAgent_RoundTripsAgentAction() throws {
        let id = try #require(UUID(uuidString: "94CF8910-15D9-4655-BC49-9F4615D52CE4"))
        let hotKey = try PushToTalkHotKey(
            keyCode: 45,
            modifiers: [.control, .option],
            keyLabel: "N")
        let configuration = try AgentHarnessConfiguration(
            preset: .custom,
            displayName: "Local agent",
            executablePath: "/Applications/Agent/bin/acp",
            arguments: ["--flag", "two words", ""],
            workingDirectory: "/Users/test/Project With Spaces",
            permissionPolicy: .reject)
        let profile = try WakeProfile(
            id: id,
            wakePhrase: "darling",
            action: .agent(configuration),
            accent: .pink,
            isEnabled: false,
            pushToTalkHotKey: hotKey)

        let roundTripped = try WakeProfileDraft(profile: profile).validatedProfile()

        #expect(roundTripped == profile)
    }

    @Test func targetKind_WhenSwitchedTwice_PreservesBothUnsavedConfigurations() throws {
        var draft = WakeProfileDraft(
            wakePhrase: "computer",
            executablePath: "/usr/bin/printf",
            argumentTemplates: ["--initial", "{text}"],
            agentHarness: AgentHarnessDraft(
                preset: .custom,
                displayName: "Initial agent",
                executablePath: "/initial/agent",
                arguments: ["--initial-agent"],
                workingDirectory: "/initial/project",
                permissionPolicy: .ask),
            targetKind: .command,
            accent: .blue)

        draft.targetKind = .agent
        draft.agentHarness.displayName = "Edited agent"
        draft.agentHarness.arguments = ["--agent", "two words"]
        draft.targetKind = .command
        draft.executablePath = "/edited/command"
        draft.argumentTemplates = ["--command", "{text}", ""]
        draft.targetKind = .agent

        #expect(draft.agentHarness.displayName == "Edited agent")
        #expect(draft.agentHarness.arguments == ["--agent", "two words"])
        #expect(draft.executablePath == "/edited/command")
        #expect(draft.argumentTemplates == ["--command", "{text}", ""])
    }

    @Test func preset_WhenCodexSelected_UsesPinnedCodexAdapterArguments() {
        var draft = AgentHarnessDraft.empty(workingDirectory: "/Users/test/project")
        let locator = executableLocator(["npx": "/opt/homebrew/bin/npx"])

        draft.selectPreset(.codex, locator: locator)

        #expect(draft.displayName == "Codex")
        #expect(draft.executablePath == "/opt/homebrew/bin/npx")
        #expect(draft.arguments == ["-y", "@agentclientprotocol/codex-acp@1.8.0"])
    }

    @Test func preset_WhenClaudeSelected_UsesPinnedClaudeAdapterArguments() {
        var draft = AgentHarnessDraft.empty(workingDirectory: "/Users/test/project")
        let locator = executableLocator(["npx": "/usr/local/bin/npx"])

        draft.selectPreset(.claude, locator: locator)

        #expect(draft.displayName == "Claude")
        #expect(draft.executablePath == "/usr/local/bin/npx")
        #expect(draft.arguments == ["-y", "@agentclientprotocol/claude-agent-acp@0.73.0"])
    }

    @Test func preset_WhenCursorSelected_UsesNativeACPArgument() {
        var draft = AgentHarnessDraft.empty(workingDirectory: "/Users/test/project")
        let locator = executableLocator(["cursor-agent": "/Users/test/.local/bin/cursor-agent"])

        draft.selectPreset(.cursor, locator: locator)

        #expect(draft.displayName == "Cursor")
        #expect(draft.executablePath == "/Users/test/.local/bin/cursor-agent")
        #expect(draft.arguments == ["acp"])
    }

    @Test func preset_WhenCustomSelected_PreservesEveryEditedField() {
        var draft = AgentHarnessDraft(
            preset: .codex,
            displayName: "My agent",
            executablePath: "/custom/agent",
            arguments: ["--custom", "two words"],
            workingDirectory: "/custom/project",
            permissionPolicy: .allowOnce)

        draft.selectPreset(.custom, locator: executableLocator([:]))

        #expect(draft == AgentHarnessDraft(
            preset: .custom,
            displayName: "My agent",
            executablePath: "/custom/agent",
            arguments: ["--custom", "two words"],
            workingDirectory: "/custom/project",
            permissionPolicy: .allowOnce))
    }

    @Test func init_WhenSavedPresetHasEditedLaunchFields_DoesNotResolvePresetAgain() throws {
        let configuration = try AgentHarnessConfiguration(
            preset: .codex,
            displayName: "Edited Codex",
            executablePath: "/custom/bin/npx",
            arguments: ["--offline", "custom-adapter"],
            workingDirectory: "/custom/project",
            permissionPolicy: .reject)
        let profile = try WakeProfile(
            wakePhrase: "computer",
            action: .agent(configuration),
            accent: .purple)

        let draft = WakeProfileDraft(profile: profile)

        #expect(draft.agentHarness == AgentHarnessDraft(configuration: configuration))
    }

    @Test func validatedProfile_WhenInactiveAgentDraftIsInvalid_ValidatesCommandOnly() throws {
        let draft = WakeProfileDraft(
            wakePhrase: "computer",
            executablePath: "/usr/bin/open",
            argumentTemplates: ["https://example.com/?q={urlText}"],
            agentHarness: .empty(workingDirectory: ""),
            targetKind: .command,
            accent: .blue)

        let profile = try draft.validatedProfile()

        #expect(profile.executablePath == "/usr/bin/open")
    }

    @Test func validatedProfile_WhenInactiveCommandDraftIsInvalid_ValidatesAgentOnly() throws {
        let draft = WakeProfileDraft(
            wakePhrase: "computer",
            executablePath: "relative-command",
            argumentTemplates: [],
            agentHarness: AgentHarnessDraft(
                preset: .custom,
                displayName: "Agent",
                executablePath: "/custom/agent",
                arguments: [],
                workingDirectory: "/custom/project",
                permissionPolicy: .ask),
            targetKind: .agent,
            accent: .blue)

        let profile = try draft.validatedProfile()

        #expect(profile.action == .agent(try draft.agentHarness.validatedConfiguration()))
    }

    private func executableLocator(_ executables: [String: String]) -> AgentExecutableLocator {
        AgentExecutableLocator(
            path: nil,
            additionalDirectories: Array(Set(executables.values.map {
                ($0 as NSString).deletingLastPathComponent
            })),
            nvmBinDirectories: [],
            isExecutableFile: { path in executables.values.contains(path) })
    }
}

import Testing
@testable import VoiceActivationApp
import VoiceActivationCore

struct AgentPermissionVoiceCommandTests {
    private let options = [
        AgentPermissionOption(id: "allow-once", label: "Allow once", kind: .allowOnce),
        AgentPermissionOption(id: "allow-always", label: "Allow always", kind: .allowAlways),
        AgentPermissionOption(id: "deny-once", label: "Deny", kind: .rejectOnce),
        AgentPermissionOption(id: "deny-always", label: "Never allow", kind: .rejectAlways),
    ]

    @Test func match_WhenSpokenChoiceNamesPermission_SelectsMatchingScope() {
        #expect(AgentPermissionVoiceCommand.match("allow", options: options)
            == .select(optionID: "allow-once"))
        #expect(AgentPermissionVoiceCommand.match("allow all", options: options)
            == .select(optionID: "allow-always"))
        #expect(AgentPermissionVoiceCommand.match("deny", options: options)
            == .select(optionID: "deny-once"))
        #expect(AgentPermissionVoiceCommand.match("deny all", options: options)
            == .select(optionID: "deny-always"))
    }

    @Test func match_WhenSpokenChoiceUsesAgentLabel_SelectsExactOption() {
        #expect(AgentPermissionVoiceCommand.match("Never allow!", options: options)
            == .select(optionID: "deny-always"))
    }

    @Test func match_WhenPhraseIsNormalFollowUp_DoesNotConsumeIt() {
        #expect(AgentPermissionVoiceCommand.match(
            "allow the tests to finish and summarize them",
            options: options) == nil)
    }

    @Test func match_WhenDenyOptionIsMissing_ReturnsSafeCancellation() {
        let allowOnly = [
            AgentPermissionOption(id: "allow-once", label: "Allow", kind: .allowOnce),
        ]

        #expect(AgentPermissionVoiceCommand.match("deny", options: allowOnly) == .cancel)
    }
}

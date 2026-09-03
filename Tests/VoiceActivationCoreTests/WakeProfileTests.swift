import Foundation
import Testing
@testable import VoiceActivationCore

struct WakeProfileTests {
    @Test func decoding_WhenProfilePredatesActionField_MigratesToCommandAction() throws {
        let legacyJSON = """
        {"id":"F39F8151-6192-452E-8C96-36D29AB7335D","wakePhrase":"sneek","executablePath":"/usr/bin/open","argumentTemplates":["https://example.com?q={urlText}"],"accent":"purple","isEnabled":false}
        """

        let profile = try JSONDecoder().decode(
            WakeProfile.self,
            from: #require(legacyJSON.data(using: .utf8)))

        let expectedAction = WakeProfileAction.command(try CommandTemplate(
            executablePath: "/usr/bin/open",
            argumentTemplates: ["https://example.com?q={urlText}"]))

        #expect(profile.action == expectedAction)
    }

    @Test func decoding_WhenLegacyProfileHasShortcut_PreservesIdentityAndShortcut() throws {
        let legacyJSON = """
        {"id":"F39F8151-6192-452E-8C96-36D29AB7335D","wakePhrase":"sneek","executablePath":"/usr/bin/open","argumentTemplates":["https://example.com?q={urlText}"],"accent":"purple","pushToTalkHotKey":{"keyCode":40,"modifiers":12,"keyLabel":"K"}}
        """

        let profile = try JSONDecoder().decode(
            WakeProfile.self,
            from: #require(legacyJSON.data(using: .utf8)))

        let expectedShortcut = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.shift, .command],
            keyLabel: "K")

        #expect(profile.id == UUID(uuidString: "F39F8151-6192-452E-8C96-36D29AB7335D"))
        #expect(profile.pushToTalkHotKey == expectedShortcut)
    }

    @Test func match_WhenSeveralProfilesCouldMatch_UsesLongestWakePhrase() throws {
        let profiles = [
            try WakeProfile(
                wakePhrase: "hey",
                urlTemplate: "https://example.com/short?q={urlText}",
                accent: .blue),
            try WakeProfile(
                wakePhrase: "hey computer",
                urlTemplate: "https://example.com/long?q={urlText}",
                accent: .purple),
        ]

        let match = WakePhraseMatcher.match(
            in: "Hey computer deploy production",
            profiles: profiles)

        #expect(match?.profile == profiles[1])
        #expect(match?.command == "deploy production")
    }

    @Test func match_WhenMatchingProfileIsDisabled_IgnoresIt() throws {
        let profile = try WakeProfile(
            wakePhrase: "sneek",
            urlTemplate: "https://example.com?q={urlText}",
            accent: .purple,
            isEnabled: false)

        let match = WakePhraseMatcher.match(
            in: "sneek remember this",
            profiles: [profile])

        #expect(match == nil)
    }

    @Test func coding_WhenProfileHasPushToTalkBinding_RoundTripsIt() throws {
        let hotKey = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        let profile = try WakeProfile(
            wakePhrase: "sneek",
            urlTemplate: "https://example.com?q={urlText}",
            accent: .purple,
            pushToTalkHotKey: hotKey)

        let decoded = try JSONDecoder().decode(
            WakeProfile.self,
            from: JSONEncoder().encode(profile))

        #expect(decoded.pushToTalkHotKey == hotKey)
    }

    @Test func init_WhenWakePhraseIsEmpty_RejectsProfile() {
        #expect(throws: WakeProfile.ValidationError.wakePhraseRequired) {
            try WakeProfile(
                wakePhrase: "   ",
                urlTemplate: "https://example.com?q={urlText}",
                accent: .cyan)
        }
    }

    @Test func init_WhenURLTemplateHasNoPlaceholder_RejectsProfile() {
        #expect(throws: WakeProfile.ValidationError.missingTranscriptPlaceholder) {
            try WakeProfile(
                wakePhrase: "computer",
                urlTemplate: "https://example.com/static",
                accent: .cyan)
        }
    }
}

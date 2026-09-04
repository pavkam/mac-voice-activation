// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

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

    @Test func init_WhenWakePhraseHasNoSpokenCharacters_RejectsProfile() {
        for wakePhrase in ["!!!", "🤖", "\u{200B}", "\u{0301}"] {
            #expect(throws: WakeProfile.ValidationError.wakePhraseRequired) {
                try WakeProfile(
                    wakePhrase: wakePhrase,
                    urlTemplate: "https://example.com?q={urlText}",
                    accent: .cyan)
            }
        }
    }

    @Test func init_WhenWakePhraseWhitespaceIsIrregular_NormalizesForRecognition() throws {
        let profile = try WakeProfile(
            wakePhrase: "  hey\t\n  computer  ",
            urlTemplate: "https://example.com?q={urlText}",
            accent: .cyan)

        #expect(profile.wakePhrase == "hey computer")
        #expect(WakePhraseMatcher.command(
            in: "hey computer open calendar",
            wakePhrase: profile.wakePhrase) == "open calendar")
    }

    @Test func init_WhenWakePhraseContainsInvisibleFormatMarks_RemovesThem() throws {
        let profile = try WakeProfile(
            wakePhrase: "com\u{200B}puter",
            urlTemplate: "https://example.com?q={urlText}",
            accent: .cyan)

        #expect(profile.wakePhrase == "computer")
        #expect(WakePhraseMatcher.command(
            in: "computer open calendar",
            wakePhrase: profile.wakePhrase) == "open calendar")
    }

    @Test func init_WhenURLTemplateHasNoPlaceholder_RejectsProfile() {
        #expect(throws: WakeProfile.ValidationError.missingTranscriptPlaceholder) {
            try WakeProfile(
                wakePhrase: "computer",
                urlTemplate: "https://example.com/static",
                accent: .cyan)
        }
    }

    @Test func activationConfiguration_WhenLegacyPhraseHasNoSpokenCharacters_UsesDefaultPhrase()
        throws
    {
        let template = try CommandTemplate(
            executablePath: "/usr/bin/printf",
            argumentTemplates: ["--message={text}"])

        let configuration = ActivationConfiguration(
            wakePhrase: "\u{0301}",
            localeID: "en-US",
            commandTemplate: template)

        #expect(configuration.profiles.first?.wakePhrase == "computer")
        #expect(configuration.profiles.first?.action == .command(template))
    }
}

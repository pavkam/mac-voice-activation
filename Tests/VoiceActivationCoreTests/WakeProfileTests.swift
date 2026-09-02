import Testing
@testable import VoiceActivationCore

struct WakeProfileTests {
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

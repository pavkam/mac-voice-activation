import Foundation
import Testing
@testable import VoiceActivationCore

struct AppPreferencesTests {
    @Test func values_WhenDefaultsAreEmpty_ReturnDocumentedDefaults() throws {
        let suite = "VoiceActivationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)

        #expect(preferences.passiveEnabled)
        #expect(preferences.wakePhrase == "computer")
        #expect(preferences.executablePath == "/usr/bin/open")
        #expect(preferences.argumentTemplates == ["https://www.google.com/search?q={urlText}"])
    }

    @Test func values_WhenChanged_RoundTripThroughDefaults() throws {
        let suite = "VoiceActivationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let writer = AppPreferences(defaults: defaults)
        writer.passiveEnabled = true
        writer.wakePhrase = "  hey mac  "
        writer.localeID = "en-GB"
        writer.executablePath = "/usr/bin/printf"
        writer.argumentTemplates = ["--", "{text}"]

        let reader = AppPreferences(defaults: defaults)

        #expect(reader.passiveEnabled)
        #expect(reader.wakePhrase == "hey mac")
        #expect(reader.localeID == "en-GB")
        #expect(reader.executablePath == "/usr/bin/printf")
        #expect(reader.argumentTemplates == ["--", "{text}"])
    }
}

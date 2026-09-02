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
        #expect(preferences.wakeProfiles == [.defaultValue])
        #expect(preferences.wakePhrase == "computer")
        #expect(preferences.pushToTalkHotKey == .defaultValue)
        #expect(preferences.executablePath == "/usr/bin/open")
        #expect(preferences.argumentTemplates == ["https://www.google.com/search?q={urlText}"])
    }

    @Test func values_WhenChanged_RoundTripThroughDefaults() throws {
        let suite = "VoiceActivationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let writer = AppPreferences(defaults: defaults)
        writer.passiveEnabled = true
        writer.wakeProfiles = [
            try WakeProfile(
                wakePhrase: "assistant",
                urlTemplate: "https://example.com?q={urlText}",
                accent: .orange),
        ]
        writer.wakePhrase = "  hey mac  "
        writer.localeID = "en-GB"
        writer.pushToTalkHotKey = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        writer.executablePath = "/usr/bin/printf"
        writer.argumentTemplates = ["--", "{text}"]

        let reader = AppPreferences(defaults: defaults)
        let expectedHotKey = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")

        #expect(reader.passiveEnabled)
        #expect(reader.wakeProfiles == writer.wakeProfiles)
        #expect(reader.wakePhrase == "hey mac")
        #expect(reader.localeID == "en-GB")
        #expect(reader.pushToTalkHotKey == expectedHotKey)
        #expect(reader.executablePath == "/usr/bin/printf")
        #expect(reader.argumentTemplates == ["--", "{text}"])
    }

    @Test func pushToTalkHotKey_WhenStoredValuesAreInvalid_ReturnsDefault() throws {
        let suite = "VoiceActivationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(40, forKey: "pushToTalkKeyCode")
        defaults.set(0, forKey: "pushToTalkModifiers")
        defaults.set("K", forKey: "pushToTalkKeyLabel")

        let preferences = AppPreferences(defaults: defaults)

        #expect(preferences.pushToTalkHotKey == .defaultValue)
    }

    @Test func wakeProfiles_WhenStoredBeforeEnabledFlagExisted_MigrateAsEnabled() throws {
        let suite = "VoiceActivationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let id = UUID(uuidString: "F39F8151-6192-452E-8C96-36D29AB7335D")!
        let legacyJSON = """
        [{"id":"\(id.uuidString)","wakePhrase":"sneek","executablePath":"/usr/bin/open","argumentTemplates":["https://example.com?q={urlText}"],"accent":"purple"}]
        """
        defaults.set(legacyJSON.data(using: .utf8), forKey: "wakeProfiles")

        let profiles = AppPreferences(defaults: defaults).wakeProfiles

        #expect(profiles.count == 1)
        #expect(profiles.first?.id == id)
        #expect(profiles.first?.wakePhrase == "sneek")
        #expect(profiles.first?.isEnabled == true)
    }

    @Test func pushToTalkURLTemplate_WhenNotStored_MigratesFromFirstWakeProfile() throws {
        let suite = "VoiceActivationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        preferences.wakeProfiles = [try WakeProfile(
            wakePhrase: "sneek",
            urlTemplate: "https://notes.example/?text={urlText}",
            accent: .purple)]

        #expect(preferences.pushToTalkURLTemplate == "https://notes.example/?text={urlText}")
    }
}

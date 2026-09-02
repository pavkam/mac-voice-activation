import Foundation
import Testing
@testable import VoiceActivationApp
import VoiceActivationCore

@MainActor
private final class ShortcutSpy: PushToTalkShortcutManaging {
    private(set) var startedHotKeys: [PushToTalkHotKey] = []
    private(set) var stopCount = 0

    func start(
        hotKey: PushToTalkHotKey,
        onPressed: @escaping () -> Void,
        onReleased: @escaping () -> Void) throws
    {
        startedHotKeys.append(hotKey)
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class AppModelOverlayStub: RecordingOverlayDisplaying {
    var onCancel: (() -> Void)?

    func show(transcript: String, accent: WakeProfileAccent) {}
    func hide() {}
}

struct AppModelTests {
    @MainActor @Test func setPushToTalkHotKey_WhenRecorded_ChangesOnlyDraft() throws {
        let fixture = try Fixture()
        let draft = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")

        fixture.model.setPushToTalkHotKey(draft)

        #expect(fixture.model.pushToTalkHotKey == draft)
        #expect(fixture.model.activePushToTalkHotKey == .defaultValue)
        #expect(fixture.preferences.pushToTalkHotKey == .defaultValue)
        #expect(fixture.shortcut.startedHotKeys.isEmpty)
    }

    @MainActor @Test func saveSettings_WhenDraftIsValid_AppliesAndPersistsHotKey() throws {
        let fixture = try Fixture()
        let draft = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        fixture.model.setPushToTalkHotKey(draft)

        let saved = fixture.model.saveSettings()

        #expect(saved)
        #expect(fixture.model.activePushToTalkHotKey == draft)
        #expect(fixture.preferences.pushToTalkHotKey == draft)
        #expect(fixture.shortcut.startedHotKeys == [draft])
    }

    @MainActor @Test func saveSettings_WhenPushToTalkURLChanges_PersistsSeparateURL() throws {
        let fixture = try Fixture()
        fixture.model.pushToTalkURLTemplate = "https://keyboard.example/?q={urlText}"

        let saved = fixture.model.saveSettings()

        #expect(saved)
        #expect(fixture.preferences.pushToTalkURLTemplate == "https://keyboard.example/?q={urlText}")
        #expect(fixture.preferences.wakeProfiles[0].argumentTemplates == [
            "https://www.google.com/search?q={urlText}",
        ])
    }

    @MainActor @Test func saveSettings_WhenProfileIsInvalid_DoesNotApplyHotKey() throws {
        let fixture = try Fixture()
        let draft = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        fixture.model.setPushToTalkHotKey(draft)
        fixture.model.wakeProfiles[0].urlTemplate = "https://example.com/static"

        let saved = fixture.model.saveSettings()

        #expect(!saved)
        #expect(fixture.model.activePushToTalkHotKey == .defaultValue)
        #expect(fixture.preferences.pushToTalkHotKey == .defaultValue)
        #expect(fixture.shortcut.startedHotKeys.isEmpty)
    }

    @MainActor @Test func saveSettings_WhenProfilesAreValid_PersistsEveryProfile() throws {
        let fixture = try Fixture()
        fixture.model.wakeProfiles = [
            WakeProfileDraft(
                wakePhrase: "search",
                urlTemplate: "https://search.example/?q={urlText}",
                accent: .cyan),
            WakeProfileDraft(
                wakePhrase: "ask assistant",
                urlTemplate: "https://assistant.example/?prompt={urlText}",
                accent: .purple),
        ]

        let saved = fixture.model.saveSettings()

        #expect(saved)
        #expect(fixture.preferences.wakeProfiles.map(\.wakePhrase) == [
            "search", "ask assistant",
        ])
        #expect(fixture.model.activeWakeProfiles.map(\.accent) == [.cyan, .purple])
    }

    @MainActor @Test func setWakeProfileEnabled_WhenOneProfileChanges_PersistsOnlyThatProfile() throws {
        let computer = try WakeProfile(
            wakePhrase: "computer",
            urlTemplate: "https://search.example/?q={urlText}",
            accent: .blue)
        let sneek = try WakeProfile(
            wakePhrase: "sneek",
            urlTemplate: "https://notes.example/?text={urlText}",
            accent: .purple)
        let fixture = try Fixture(profiles: [computer, sneek])

        fixture.model.setWakeProfileEnabled(sneek.id, enabled: false)

        #expect(fixture.model.activeWakeProfiles.map(\.isEnabled) == [true, false])
        #expect(fixture.model.wakeProfiles.map(\.isEnabled) == [true, false])
        #expect(fixture.preferences.wakeProfiles.map(\.isEnabled) == [true, false])
    }

    @MainActor @Test func shortcutRecording_WhenDraftIsNotSaved_RestoresActiveHotKey() throws {
        let fixture = try Fixture()
        let draft = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        fixture.model.setPushToTalkHotKey(draft)

        fixture.model.setPushToTalkShortcutRecording(true)
        fixture.model.setPushToTalkShortcutRecording(false)

        #expect(fixture.shortcut.stopCount == 1)
        #expect(fixture.shortcut.startedHotKeys == [.defaultValue])
        #expect(fixture.preferences.pushToTalkHotKey == .defaultValue)
    }

    @MainActor
    private struct Fixture {
        let preferences: AppPreferences
        let shortcut = ShortcutSpy()
        let model: AppModel

        init(profiles: [WakeProfile]? = nil) throws {
            let suite = "VoiceActivationAppModelTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            preferences = AppPreferences(defaults: defaults)
            if let profiles {
                preferences.wakeProfiles = profiles
            }
            model = AppModel(
                preferences: preferences,
                recordingOverlay: AppModelOverlayStub(),
                shortcut: shortcut,
                startsAutomatically: false)
        }
    }
}

import Foundation
import Testing
@testable import VoiceActivationApp
import VoiceActivationCore

@MainActor
private final class ShortcutSpy: PushToTalkShortcutManaging {
    private(set) var startedProfiles: [[WakeProfile]] = []
    private(set) var stopCount = 0

    func start(
        profiles: [WakeProfile],
        onPressed: @escaping (UUID) -> Void,
        onReleased: @escaping (UUID) -> Void) throws
    {
        startedProfiles.append(profiles)
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
    @MainActor @Test func setPushToTalkHotKey_WhenRecorded_ChangesOnlyThatProfileDraft() throws {
        let fixture = try Fixture()
        let profileID = fixture.model.wakeProfiles[0].id
        let draft = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")

        fixture.model.setPushToTalkHotKey(draft, for: profileID)

        #expect(fixture.model.wakeProfiles[0].pushToTalkHotKey == draft)
        #expect(fixture.model.activeWakeProfiles[0].pushToTalkHotKey == .defaultValue)
        #expect(fixture.preferences.wakeProfiles[0].pushToTalkHotKey == .defaultValue)
        #expect(fixture.shortcut.startedProfiles.isEmpty)
    }

    @MainActor @Test func saveSettings_WhenDraftIsValid_AppliesAndPersistsHotKey() throws {
        let fixture = try Fixture()
        let profileID = fixture.model.wakeProfiles[0].id
        let draft = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        fixture.model.setPushToTalkHotKey(draft, for: profileID)

        let saved = fixture.model.saveSettings()

        #expect(saved)
        #expect(fixture.model.activeWakeProfiles[0].pushToTalkHotKey == draft)
        #expect(fixture.preferences.wakeProfiles[0].pushToTalkHotKey == draft)
        #expect(fixture.shortcut.startedProfiles.last?[0].pushToTalkHotKey == draft)
    }

    @MainActor @Test func saveSettings_WhenProfileIsInvalid_DoesNotApplyHotKey() throws {
        let fixture = try Fixture()
        let profileID = fixture.model.wakeProfiles[0].id
        let draft = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        fixture.model.setPushToTalkHotKey(draft, for: profileID)
        fixture.model.wakeProfiles[0].urlTemplate = "https://example.com/static"

        let saved = fixture.model.saveSettings()

        #expect(!saved)
        #expect(fixture.model.activeWakeProfiles[0].pushToTalkHotKey == .defaultValue)
        #expect(fixture.preferences.wakeProfiles[0].pushToTalkHotKey == .defaultValue)
        #expect(fixture.shortcut.startedProfiles.isEmpty)
    }

    @MainActor @Test func saveSettings_WhenProfilesAreValid_PersistsEveryProfile() throws {
        let fixture = try Fixture()
        let searchHotKey = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        let assistantHotKey = try PushToTalkHotKey(
            keyCode: 45,
            modifiers: [.control, .option],
            keyLabel: "N")
        fixture.model.wakeProfiles = [
            WakeProfileDraft(
                wakePhrase: "search",
                urlTemplate: "https://search.example/?q={urlText}",
                accent: .cyan,
                pushToTalkHotKey: searchHotKey),
            WakeProfileDraft(
                wakePhrase: "ask assistant",
                urlTemplate: "https://assistant.example/?prompt={urlText}",
                accent: .purple,
                pushToTalkHotKey: assistantHotKey),
        ]

        let saved = fixture.model.saveSettings()

        #expect(saved)
        #expect(fixture.preferences.wakeProfiles.map(\.wakePhrase) == [
            "search", "ask assistant",
        ])
        #expect(fixture.model.activeWakeProfiles.map(\.accent) == [.cyan, .purple])
        #expect(fixture.shortcut.startedProfiles.last?.map(\.pushToTalkHotKey) == [
            searchHotKey, assistantHotKey,
        ])
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
        let profileID = fixture.model.wakeProfiles[0].id
        let draft = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        fixture.model.setPushToTalkHotKey(draft, for: profileID)

        fixture.model.setPushToTalkShortcutRecording(true)
        fixture.model.setPushToTalkShortcutRecording(false)

        #expect(fixture.shortcut.stopCount == 1)
        #expect(fixture.shortcut.startedProfiles.last?[0].pushToTalkHotKey == .defaultValue)
        #expect(fixture.preferences.wakeProfiles[0].pushToTalkHotKey == .defaultValue)
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

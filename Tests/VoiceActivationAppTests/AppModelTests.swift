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

    func show(transcript: String) {}
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

    @MainActor @Test func saveSettings_WhenCommandIsInvalid_DoesNotApplyHotKey() throws {
        let fixture = try Fixture()
        let draft = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        fixture.model.setPushToTalkHotKey(draft)
        fixture.model.executablePath = "relative-command"

        let saved = fixture.model.saveSettings()

        #expect(!saved)
        #expect(fixture.model.activePushToTalkHotKey == .defaultValue)
        #expect(fixture.preferences.pushToTalkHotKey == .defaultValue)
        #expect(fixture.shortcut.startedHotKeys.isEmpty)
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

        init() throws {
            let suite = "VoiceActivationAppModelTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            preferences = AppPreferences(defaults: defaults)
            model = AppModel(
                preferences: preferences,
                recordingOverlay: AppModelOverlayStub(),
                shortcut: shortcut,
                startsAutomatically: false)
        }
    }
}

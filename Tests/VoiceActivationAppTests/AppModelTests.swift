import Foundation
import Testing
@testable import VoiceActivationApp
import VoiceActivationCore

@MainActor
private final class ShortcutSpy: PushToTalkShortcutManaging {
    private(set) var startedProfiles: [[WakeProfile]] = []
    private(set) var stopCount = 0
    private var onPressed: ((UUID) -> Void)?

    func start(
        profiles: [WakeProfile],
        onPressed: @escaping (UUID) -> Void,
        onReleased: @escaping (UUID) -> Void) throws
    {
        startedProfiles.append(profiles)
        self.onPressed = onPressed
    }

    func stop() {
        stopCount += 1
    }

    func press(_ profileID: UUID) {
        onPressed?(profileID)
    }
}

@MainActor
private final class AppModelOverlayStub: RecordingOverlayDisplaying {
    var onCancel: (() -> Void)?

    func show(transcript: String, accent: WakeProfileAccent) {}
    func hide() {}
}

@MainActor
private final class AppModelSpeechSessionSpy: SpeechSessionProtocol {
    private(set) var startCount = 0

    func start(
        mode: SpeechSessionMode,
        localeID: String,
        contextualStrings: [String],
        onUpdate: @escaping (SpeechUpdate) -> Void,
        onInterruption: @escaping () -> Void) throws
    {
        startCount += 1
    }

    func stop() {}
}

@MainActor
private final class PermissionRequestGate {
    private var continuations: [CheckedContinuation<Bool, Never>] = []
    private(set) var requestCount = 0
    private(set) var completionCount = 0
    var isWaiting: Bool { !continuations.isEmpty }

    func request() async -> Bool {
        requestCount += 1
        let granted = await withCheckedContinuation { continuations.append($0) }
        completionCount += 1
        return granted
    }

    func resolve(_ granted: Bool) {
        let pending = continuations
        continuations = []
        for continuation in pending {
            continuation.resume(returning: granted)
        }
    }
}

struct AppModelTests {
    @MainActor @Test func start_WhenPassiveListeningIsEnabled_WiresAndStartsDependencies() async throws {
        let suite = "VoiceActivationStartupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        let speech = AppModelSpeechSessionSpy()
        let shortcut = ShortcutSpy()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            shortcut: shortcut,
            speechSession: speech,
            permissionRequest: { true },
            startsAutomatically: false)

        await model.start()

        #expect(model.state == .listening)
        #expect(speech.startCount == 1)
        #expect(shortcut.startedProfiles.count == 1)
    }

    @MainActor @Test func start_WhenCalledTwice_StartsDependenciesOnce() async throws {
        let suite = "VoiceActivationStartupIdempotencyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        let speech = AppModelSpeechSessionSpy()
        let shortcut = ShortcutSpy()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            shortcut: shortcut,
            speechSession: speech,
            permissionRequest: { true },
            startsAutomatically: false)

        await model.start()
        await model.start()

        #expect(speech.startCount == 1)
        #expect(shortcut.startedProfiles.count == 1)
    }

    @MainActor @Test func passiveListening_WhenDisabledDuringPermissionRequest_StaysOff() async throws {
        let suite = "VoiceActivationPermissionRaceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        preferences.passiveEnabled = false
        let speech = AppModelSpeechSessionSpy()
        let permission = PermissionRequestGate()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            shortcut: ShortcutSpy(),
            speechSession: speech,
            permissionRequest: { await permission.request() },
            startsAutomatically: false)

        model.setPassiveEnabled(true)
        await waitUntil { permission.isWaiting }
        #expect(permission.isWaiting)
        model.setPassiveEnabled(false)
        permission.resolve(true)
        await Task.yield()

        #expect(!model.passiveEnabled)
        #expect(!preferences.passiveEnabled)
        #expect(speech.startCount == 0)
    }

    @MainActor @Test func passiveListening_WhenDisabledBeforePermissionDenial_DoesNotShowFailure() async throws {
        let suite = "VoiceActivationLatePermissionDenialTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        preferences.passiveEnabled = false
        let permission = PermissionRequestGate()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            shortcut: ShortcutSpy(),
            speechSession: AppModelSpeechSessionSpy(),
            permissionRequest: { await permission.request() },
            startsAutomatically: false)

        model.setPassiveEnabled(true)
        await waitUntil { permission.isWaiting }
        model.setPassiveEnabled(false)
        permission.resolve(false)
        await waitUntil { permission.completionCount == 1 }

        #expect(model.state == .disabled)
    }

    @MainActor @Test func passiveListening_WhenSettingDoesNotChange_DoesNotRequestPermissions() async throws {
        let suite = "VoiceActivationIdempotentToggleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        let permission = PermissionRequestGate()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            shortcut: ShortcutSpy(),
            speechSession: AppModelSpeechSessionSpy(),
            permissionRequest: { await permission.request() },
            startsAutomatically: false)

        model.setPassiveEnabled(true)
        await Task.yield()

        #expect(permission.requestCount == 0)
        if permission.isWaiting {
            permission.resolve(false)
        }
    }

    @MainActor @Test func permissions_WhenStartupAndPushToTalkOverlap_RequestsOnce() async throws {
        let suite = "VoiceActivationPermissionCoalescingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        let permission = PermissionRequestGate()
        let shortcut = ShortcutSpy()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            shortcut: shortcut,
            speechSession: AppModelSpeechSessionSpy(),
            permissionRequest: { await permission.request() },
            startsAutomatically: false)
        let startup = Task { @MainActor in await model.start() }
        await waitUntil { permission.isWaiting && !shortcut.startedProfiles.isEmpty }
        let profileID = try #require(shortcut.startedProfiles.first?.first?.id)

        shortcut.press(profileID)
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(permission.requestCount == 1)
        permission.resolve(true)
        await startup.value
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool) async
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

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

    @MainActor @Test func saveSettings_WhenPhrasesMatchAfterNormalization_RejectsProfiles() throws {
        let fixture = try Fixture()
        fixture.model.wakeProfiles = [
            WakeProfileDraft(
                wakePhrase: "Computer",
                urlTemplate: "https://one.example/?q={urlText}",
                accent: .blue),
            WakeProfileDraft(
                wakePhrase: "computer!",
                urlTemplate: "https://two.example/?q={urlText}",
                accent: .purple),
        ]

        let saved = fixture.model.saveSettings()

        #expect(!saved)
        #expect(fixture.model.settingsError == "Wake phrases must be unique.")
        #expect(fixture.shortcut.startedProfiles.isEmpty)
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

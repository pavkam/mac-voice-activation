import Foundation
import Testing
@testable import VoiceActivationApp
import VoiceActivationCore

@MainActor
private final class ShortcutSpy: PushToTalkShortcutManaging {
    private(set) var startedProfiles: [[WakeProfile]] = []
    private(set) var registeredProfiles: [WakeProfile] = []
    private(set) var stopCount = 0
    private var onPressed: ((UUID) -> Void)?
    private var onReleased: ((UUID) -> Void)?
    var failNextStart = false

    func start(
        profiles: [WakeProfile],
        onPressed: @escaping (UUID) -> Void,
        onReleased: @escaping (UUID) -> Void) throws
    {
        startedProfiles.append(profiles)
        if failNextStart {
            failNextStart = false
            throw ShortcutSpyError.registrationFailed
        }
        registeredProfiles = profiles
        self.onPressed = onPressed
        self.onReleased = onReleased
    }

    func stop() {
        stopCount += 1
    }

    func press(_ profileID: UUID) {
        onPressed?(profileID)
    }

    func release(_ profileID: UUID) {
        onReleased?(profileID)
    }
}

private enum ShortcutSpyError: Error, LocalizedError {
    case registrationFailed

    var errorDescription: String? { "Shortcut registration failed." }
}

@MainActor
private final class AppModelOverlayStub: RecordingOverlayDisplaying {
    var onCancel: (() -> Void)?
    private(set) var shownAccents: [WakeProfileAccent] = []

    func show(transcript: String, accent: WakeProfileAccent) {
        shownAccents.append(accent)
    }
    func hide() {}
}

@MainActor
private final class AppModelAgentPanelSpy: AgentRunPanelDisplaying {
    var onAction: ((AgentRunPanelAction) -> Void)?
    private(set) var began: [AgentRunSnapshot] = []
    private(set) var updates: [AgentRunSnapshot] = []
    private(set) var shown: [UUID] = []
    private(set) var hidden: [UUID] = []

    func begin(_ snapshot: AgentRunSnapshot, from handoff: RecordingOverlayHandoff?) {
        began.append(snapshot)
    }

    func update(_ snapshot: AgentRunSnapshot) { updates.append(snapshot) }
    func show(runID: UUID) { shown.append(runID) }
    func hide(runID: UUID) { hidden.append(runID) }
}

@MainActor
private final class AppModelSpeechSessionSpy: SpeechSessionProtocol {
    private(set) var startCount = 0
    private(set) var mode: SpeechSessionMode?
    private var onUpdate: ((SpeechUpdate) -> Void)?

    func start(
        mode: SpeechSessionMode,
        localeID: String,
        contextualStrings: [String],
        onUpdate: @escaping (SpeechUpdate) -> Void,
        onInterruption: @escaping () -> Void) throws
    {
        startCount += 1
        self.mode = mode
        self.onUpdate = onUpdate
    }

    func stop() {
        mode = nil
        onUpdate = nil
    }

    func emit(_ transcript: String, isFinal: Bool = false) {
        onUpdate?(SpeechUpdate(
            transcript: transcript,
            isFinal: isFinal,
            errorDescription: nil))
    }
}

private actor AppModelAgentRunnerSpy: AgentHarnessRunning {
    struct Invocation: Equatable, Sendable {
        let profileID: UUID
        let configuration: AgentHarnessConfiguration
        let prompt: String
    }

    private var invocations: [Invocation] = []
    private var resets: [Set<UUID>] = []
    private var shouldDelayReset = false
    private var resetContinuation: CheckedContinuation<Void, Never>?
    private let events: [AgentRunEvent]

    init(events: [AgentRunEvent] = []) {
        self.events = events
    }

    func run(
        profileID: UUID,
        configuration: AgentHarnessConfiguration,
        prompt: String,
        onEvent: @escaping @Sendable (AgentRunEvent) async -> Void
    ) async throws -> AgentRunResult {
        invocations.append(Invocation(
            profileID: profileID,
            configuration: configuration,
            prompt: prompt))
        for event in events {
            await onEvent(event)
        }
        return AgentRunResult(stopReason: .endTurn)
    }

    func resolvePermission(
        turnToken: AgentTurnToken,
        requestID: ACPRequestID,
        optionID: String?) async {}

    func cancel() async {}

    func reset(profileIDs: Set<UUID>) async {
        resets.append(profileIDs)
        guard shouldDelayReset else { return }
        await withCheckedContinuation { resetContinuation = $0 }
    }

    func shutdown() async {}

    func recordedInvocations() -> [Invocation] { invocations }
    func recordedResets() -> [Set<UUID>] { resets }
    func delayReset() { shouldDelayReset = true }
    func resetIsWaiting() -> Bool { resetContinuation != nil }
    func releaseReset() {
        shouldDelayReset = false
        resetContinuation?.resume()
        resetContinuation = nil
    }
}

@MainActor
private final class AppModelAgentConversationAudioSpy: AgentConversationAudioPlaying {
    var onSpeakingChange: ((Bool) -> Void)?
    private(set) var spoken: [(text: String, localeID: String)] = []

    func setWorking(_ working: Bool) {}

    func speak(_ text: String, localeID: String) {
        spoken.append((text, localeID))
        onSpeakingChange?(true)
    }

    func stopSpeaking() {
        onSpeakingChange?(false)
    }

    func stopAll() {
        onSpeakingChange?(false)
    }
}

@MainActor
private final class AgentSpeechCredentialStoreSpy: AgentSpeechCredentialStoring {
    private(set) var apiKey: String?
    private(set) var savedKeys: [String?] = []

    init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    func loadElevenLabsAPIKey() throws -> String? {
        apiKey
    }

    func saveElevenLabsAPIKey(_ apiKey: String?) throws {
        self.apiKey = apiKey
        savedKeys.append(apiKey)
    }
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
    @MainActor @Test func togglePassiveListening_WhenProfilesDiffer_PausesWithoutChangingProfiles() throws {
        let computer = try WakeProfile(
            wakePhrase: "computer",
            urlTemplate: "https://one.example/?q={urlText}",
            accent: .blue,
            isEnabled: true)
        let sneek = try WakeProfile(
            wakePhrase: "sneek",
            urlTemplate: "https://two.example/?q={urlText}",
            accent: .purple,
            isEnabled: false)
        let fixture = try Fixture(profiles: [computer, sneek])

        fixture.model.togglePassiveListening()

        #expect(!fixture.model.passiveEnabled)
        #expect(!fixture.preferences.passiveEnabled)
        #expect(fixture.model.activeWakeProfiles.map(\.isEnabled) == [true, false])
    }

    @MainActor @Test func togglePassiveListening_WhenPaused_ResumesPreviousProfiles() async throws {
        let suite = "VoiceActivationResumeAllTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        preferences.passiveEnabled = false
        let profiles = [
            try WakeProfile(
                wakePhrase: "computer",
                urlTemplate: "https://one.example/?q={urlText}",
                accent: .blue,
                isEnabled: true),
            try WakeProfile(
                wakePhrase: "sneek",
                urlTemplate: "https://two.example/?q={urlText}",
                accent: .purple,
                isEnabled: false),
        ]
        preferences.wakeProfiles = profiles
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            shortcut: ShortcutSpy(),
            speechSession: AppModelSpeechSessionSpy(),
            permissionRequest: { true },
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
            startsAutomatically: false)

        await model.start()
        model.togglePassiveListening()
        await waitUntil { model.state == .listening }

        #expect(model.passiveEnabled)
        #expect(preferences.passiveEnabled)
        #expect(model.activeWakeProfiles.map(\.isEnabled) == [true, false])
    }

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
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
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
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
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
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
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
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
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
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
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
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
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

    @MainActor @Test func shutdown_WhenStartupPermissionCompletesLate_DoesNotRestartListening()
        async throws
    {
        let suite = "VoiceActivationShutdownPermissionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        let permission = PermissionRequestGate()
        let speech = AppModelSpeechSessionSpy()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            shortcut: ShortcutSpy(),
            speechSession: speech,
            permissionRequest: { await permission.request() },
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
            startsAutomatically: false)
        let startup = Task { @MainActor in await model.start() }
        await waitUntil { permission.isWaiting }

        model.shutdown()
        permission.resolve(true)
        await startup.value

        #expect(speech.startCount == 0)
        #expect(model.state == .disabled)
    }

    @MainActor @Test func start_WhenPassiveDisabledDuringPermissionRequest_StaysOff() async throws {
        let suite = "VoiceActivationStartupPausePermissionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        let permission = PermissionRequestGate()
        let speech = AppModelSpeechSessionSpy()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            shortcut: ShortcutSpy(),
            speechSession: speech,
            permissionRequest: { await permission.request() },
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
            startsAutomatically: false)
        let startup = Task { @MainActor in await model.start() }
        await waitUntil { permission.isWaiting }

        model.setPassiveEnabled(false)
        permission.resolve(true)
        await startup.value

        #expect(!model.passiveEnabled)
        #expect(speech.startCount == 0)
        #expect(model.state == .disabled)
    }

    @MainActor @Test func pushToTalk_WhenHeldProfileChangesDuringPermission_UsesNewestBinding()
        async throws
    {
        let suite = "VoiceActivationHotKeyPermissionRaceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        preferences.passiveEnabled = false
        let firstProfile = try WakeProfile(
            wakePhrase: "computer",
            urlTemplate: "https://one.example/?q={urlText}",
            accent: .blue,
            pushToTalkHotKey: try PushToTalkHotKey(
                keyCode: 40,
                modifiers: [.command, .shift],
                keyLabel: "K"))
        let secondProfile = try WakeProfile(
            wakePhrase: "sneek",
            urlTemplate: "https://two.example/?q={urlText}",
            accent: .purple,
            pushToTalkHotKey: try PushToTalkHotKey(
                keyCode: 45,
                modifiers: [.control, .option],
                keyLabel: "N"))
        preferences.wakeProfiles = [firstProfile, secondProfile]
        let permission = PermissionRequestGate()
        let shortcut = ShortcutSpy()
        let speech = AppModelSpeechSessionSpy()
        let overlay = AppModelOverlayStub()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: overlay,
            shortcut: shortcut,
            speechSession: speech,
            permissionRequest: { await permission.request() },
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
            startsAutomatically: false)
        await model.start()

        shortcut.press(firstProfile.id)
        await waitUntil { permission.isWaiting }
        shortcut.release(firstProfile.id)
        shortcut.press(secondProfile.id)
        permission.resolve(true)
        await waitUntil { speech.mode == .pushToTalk }

        #expect(overlay.shownAccents.last == .purple)
        shortcut.release(secondProfile.id)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () async -> Bool) async
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        if !(await condition()) {
            Issue.record("Condition was not satisfied before timeout")
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

    @MainActor @Test func saveSettings_WhenDraftIsValid_AppliesAndPersistsHotKey() async throws {
        let fixture = try Fixture()
        let profileID = fixture.model.wakeProfiles[0].id
        let draft = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        fixture.model.setPushToTalkHotKey(draft, for: profileID)

        let saved = await fixture.model.saveSettings()

        #expect(saved)
        #expect(fixture.model.activeWakeProfiles[0].pushToTalkHotKey == draft)
        #expect(fixture.preferences.wakeProfiles[0].pushToTalkHotKey == draft)
        #expect(fixture.shortcut.startedProfiles.last?[0].pushToTalkHotKey == draft)
    }

    @MainActor @Test func saveSettings_WhenProfileIsInvalid_DoesNotApplyHotKey() async throws {
        let fixture = try Fixture()
        let profileID = fixture.model.wakeProfiles[0].id
        let draft = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        fixture.model.setPushToTalkHotKey(draft, for: profileID)
        fixture.model.wakeProfiles[0].urlTemplate = "https://example.com/static"

        let saved = await fixture.model.saveSettings()

        #expect(!saved)
        #expect(fixture.model.activeWakeProfiles[0].pushToTalkHotKey == .defaultValue)
        #expect(fixture.preferences.wakeProfiles[0].pushToTalkHotKey == .defaultValue)
        #expect(fixture.shortcut.startedProfiles.isEmpty)
    }

    @MainActor @Test func saveSettings_WhenProfilesAreValid_PersistsEveryProfile() async throws {
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

        let saved = await fixture.model.saveSettings()

        #expect(saved)
        #expect(fixture.preferences.wakeProfiles.map(\.wakePhrase) == [
            "search", "ask assistant",
        ])
        #expect(fixture.model.activeWakeProfiles.map(\.accent) == [.cyan, .purple])
        #expect(fixture.shortcut.startedProfiles.last?.map(\.pushToTalkHotKey) == [
            searchHotKey, assistantHotKey,
        ])
    }

    @MainActor @Test func saveSettings_WhenPhrasesMatchAfterNormalization_RejectsProfiles() async throws {
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

        let saved = await fixture.model.saveSettings()

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

    @MainActor @Test func saveSettings_WhenAgentExecutableIsMissing_PreservesActiveProfilesAndHotKeys() async throws {
        let runner = AppModelAgentRunnerSpy()
        let profile = try makeAgentProfile(
            executablePath: "/missing/agent",
            pushToTalkHotKey: .defaultValue)
        let fixture = try Fixture(
            profiles: [profile],
            agentRunner: runner,
            isExecutableFile: { _ in false },
            isDirectory: { _ in true })
        await fixture.model.start()
        let activeProfiles = fixture.model.activeWakeProfiles
        let registeredProfiles = fixture.shortcut.registeredProfiles
        let savedLocale = fixture.preferences.localeID
        fixture.model.localeID = "fr-FR"

        let saved = await fixture.model.saveSettings()

        #expect(!saved)
        #expect(fixture.model.activeWakeProfiles == activeProfiles)
        #expect(fixture.preferences.wakeProfiles == activeProfiles)
        #expect(fixture.preferences.localeID == savedLocale)
        #expect(fixture.shortcut.registeredProfiles == registeredProfiles)
        #expect(fixture.shortcut.startedProfiles == [registeredProfiles])
        #expect(await runner.recordedResets().isEmpty)
    }

    @MainActor @Test func saveSettings_WhenWorkingDirectoryIsNotDirectory_PreservesActiveProfiles() async throws {
        let runner = AppModelAgentRunnerSpy()
        let profile = try makeAgentProfile(workingDirectory: "/Users/test/not-a-directory")
        let fixture = try Fixture(
            profiles: [profile],
            agentRunner: runner,
            isExecutableFile: { _ in true },
            isDirectory: { _ in false })
        let activeProfiles = fixture.model.activeWakeProfiles

        let saved = await fixture.model.saveSettings()

        #expect(!saved)
        #expect(fixture.model.activeWakeProfiles == activeProfiles)
        #expect(fixture.preferences.wakeProfiles == activeProfiles)
        #expect(fixture.shortcut.startedProfiles.isEmpty)
        #expect(await runner.recordedResets().isEmpty)
    }

    @MainActor @Test func saveSettings_WhenCommandExecutableIsMissing_PreservesActiveProfiles() async throws {
        let runner = AppModelAgentRunnerSpy()
        let fixture = try Fixture(
            agentRunner: runner,
            isExecutableFile: { _ in false })
        let activeProfiles = fixture.model.activeWakeProfiles

        let saved = await fixture.model.saveSettings()

        #expect(!saved)
        #expect(fixture.model.activeWakeProfiles == activeProfiles)
        #expect(fixture.preferences.wakeProfiles == activeProfiles)
        #expect(fixture.shortcut.startedProfiles.isEmpty)
        #expect(await runner.recordedResets().isEmpty)
    }

    @MainActor @Test func saveSettings_WhenShortcutReplacementFails_RestoresExactPreviousRegistrations() async throws {
        let oldHotKey = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        let newHotKey = try PushToTalkHotKey(
            keyCode: 45,
            modifiers: [.control, .option],
            keyLabel: "N")
        let oldProfiles = [try WakeProfile(
            wakePhrase: "computer",
            urlTemplate: "https://example.com/?q={urlText}",
            accent: .blue,
            pushToTalkHotKey: oldHotKey)]
        let runner = AppModelAgentRunnerSpy()
        let fixture = try Fixture(profiles: oldProfiles, agentRunner: runner)
        await fixture.model.start()
        fixture.model.setPushToTalkHotKey(newHotKey, for: oldProfiles[0].id)
        fixture.shortcut.failNextStart = true

        let saved = await fixture.model.saveSettings()

        #expect(!saved)
        #expect(fixture.shortcut.startedProfiles.count == 2)
        #expect(fixture.shortcut.startedProfiles[0] == oldProfiles)
        #expect(fixture.shortcut.startedProfiles[1][0].pushToTalkHotKey == newHotKey)
        #expect(fixture.shortcut.registeredProfiles == oldProfiles)
        #expect(fixture.model.activeWakeProfiles == oldProfiles)
        #expect(fixture.preferences.wakeProfiles == oldProfiles)
        #expect(await runner.recordedResets().isEmpty)
    }

    @MainActor @Test func saveSettings_WhenAgentProfilesChange_ResetsOnlyAffectedCachedProfiles() async throws {
        let changed = try makeAgentProfile(
            id: UUID(),
            displayName: "Changed",
            executablePath: "/agents/changed-old")
        let removed = try makeAgentProfile(
            id: UUID(),
            displayName: "Removed",
            executablePath: "/agents/removed")
        let convertedToCommand = try makeAgentProfile(
            id: UUID(),
            displayName: "Converted",
            executablePath: "/agents/converted")
        let metadataOnly = try makeAgentProfile(
            id: UUID(),
            displayName: "Metadata only",
            executablePath: "/agents/metadata")
        let convertedToAgent = try WakeProfile(
            id: UUID(),
            wakePhrase: "command",
            executablePath: "/usr/bin/open",
            argumentTemplates: ["https://example.com/?q={urlText}"],
            accent: .green)
        let runner = AppModelAgentRunnerSpy()
        let fixture = try Fixture(
            profiles: [changed, removed, convertedToCommand, metadataOnly, convertedToAgent],
            agentRunner: runner,
            isExecutableFile: { _ in true },
            isDirectory: { _ in true })

        var changedDraft = WakeProfileDraft(profile: changed)
        changedDraft.agentHarness.executablePath = "/agents/changed-new"
        var convertedCommandDraft = WakeProfileDraft(profile: convertedToCommand)
        convertedCommandDraft.targetKind = .command
        convertedCommandDraft.executablePath = "/usr/bin/open"
        convertedCommandDraft.argumentTemplates = ["https://example.com/?q={urlText}"]
        var metadataDraft = WakeProfileDraft(profile: metadataOnly)
        metadataDraft.wakePhrase = "metadata renamed"
        var convertedAgentDraft = WakeProfileDraft(profile: convertedToAgent)
        convertedAgentDraft.targetKind = .agent
        convertedAgentDraft.agentHarness = AgentHarnessDraft(
            preset: .custom,
            displayName: "New agent",
            executablePath: "/agents/new",
            arguments: [],
            workingDirectory: "/projects/new",
            permissionPolicy: .ask)
        fixture.model.wakeProfiles = [
            changedDraft,
            convertedCommandDraft,
            metadataDraft,
            convertedAgentDraft,
        ]

        let saved = await fixture.model.saveSettings()

        #expect(saved)
        #expect(await runner.recordedResets() == [[
            changed.id,
            removed.id,
            convertedToCommand.id,
        ]])
    }

    @MainActor @Test func coordinator_WhenAgentRunnerIsInjected_UsesSameInstanceAsSettingsReset() async throws {
        let profile = try makeAgentProfile(pushToTalkHotKey: .defaultValue)
        let runner = AppModelAgentRunnerSpy()
        let fixture = try Fixture(
            profiles: [profile],
            agentRunner: runner,
            isExecutableFile: { _ in true },
            isDirectory: { _ in true })
        await fixture.model.start()

        fixture.shortcut.press(profile.id)
        await waitUntil { fixture.speech.mode == .pushToTalk }
        fixture.speech.emit("inspect this repository")
        fixture.shortcut.release(profile.id)
        await waitUntil { await runner.recordedInvocations().count == 1 }

        let invocation = try #require(await runner.recordedInvocations().first)
        #expect(invocation.profileID == profile.id)
        #expect(invocation.prompt == "inspect this repository")

        fixture.model.wakeProfiles[0].agentHarness.executablePath = "/agents/changed"
        let saved = await fixture.model.saveSettings()

        #expect(saved)
        #expect(await runner.recordedResets() == [[profile.id]])
    }

    @MainActor @Test func pushToTalk_WhenAnotherProfileReleases_KeepsOriginalCaptureActive()
        async throws
    {
        let firstHotKey = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        let secondHotKey = try PushToTalkHotKey(
            keyCode: 45,
            modifiers: [.control, .option],
            keyLabel: "N")
        let firstProfile = try WakeProfile(
            wakePhrase: "computer",
            urlTemplate: "https://one.example/?q={urlText}",
            accent: .blue,
            pushToTalkHotKey: firstHotKey)
        let secondProfile = try WakeProfile(
            wakePhrase: "sneek",
            urlTemplate: "https://two.example/?q={urlText}",
            accent: .purple,
            pushToTalkHotKey: secondHotKey)
        let fixture = try Fixture(profiles: [firstProfile, secondProfile])
        await fixture.model.start()
        fixture.shortcut.press(firstProfile.id)
        await waitUntil { fixture.speech.mode == .pushToTalk }

        fixture.shortcut.press(secondProfile.id)
        fixture.shortcut.release(secondProfile.id)

        #expect(fixture.speech.mode == .pushToTalk)
        #expect(fixture.model.state == .capturing)
        fixture.shortcut.release(firstProfile.id)
    }

    @MainActor @Test func saveSettings_WhenSaveIsInFlight_RejectsOverlappingSave() async throws {
        let profile = try makeAgentProfile(executablePath: "/agents/original")
        let runner = AppModelAgentRunnerSpy()
        let fixture = try Fixture(
            profiles: [profile],
            agentRunner: runner,
            isExecutableFile: { _ in true },
            isDirectory: { _ in true })
        await runner.delayReset()
        fixture.model.wakeProfiles[0].agentHarness.executablePath = "/agents/changed"
        let firstSave = Task { @MainActor in await fixture.model.saveSettings() }
        await waitUntil { await runner.resetIsWaiting() }

        let overlappingSave = await fixture.model.saveSettings()

        #expect(!overlappingSave)
        #expect(fixture.model.isSavingSettings)
        await runner.releaseReset()
        #expect(await firstSave.value)
        #expect(!fixture.model.isSavingSettings)
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

    @MainActor @Test func agentLifecycle_WhenRunStreams_OpensUpdatesAndRetainsPanel() throws {
        let profile = try makeAgentProfile(displayName: "Codex")
        let panel = AppModelAgentPanelSpy()
        let fixture = try Fixture(profiles: [profile], agentRunPanel: panel)
        let runID = UUID()

        fixture.model.handleAgentRunLifecycleEvent(.started(
            runID: runID,
            profile: profile,
            prompt: "Explain the change"))
        fixture.model.handleAgentRunLifecycleEvent(.event(
            runID: runID,
            event: .agentMessageDelta(messageID: nil, text: "Done")))
        fixture.model.handleAgentRunLifecycleEvent(.completed(
            runID: runID,
            result: AgentRunResult(stopReason: .endTurn)))
        fixture.model.showAgentRun()

        #expect(panel.began.count == 1)
        #expect(fixture.model.agentRunSnapshot?.output == "Done")
        #expect(fixture.model.agentRunSnapshot?.phase == .completed(.endTurn))
        #expect(panel.shown == [runID])
    }

    @MainActor @Test func deleteAgentRun_WhenConversationIsTerminal_DiscardsItAndHidesPanel()
        throws
    {
        let profile = try makeAgentProfile(displayName: "Codex")
        let panel = AppModelAgentPanelSpy()
        let fixture = try Fixture(profiles: [profile], agentRunPanel: panel)
        let runID = UUID()
        fixture.model.handleAgentRunLifecycleEvent(.started(
            runID: runID,
            profile: profile,
            prompt: "Explain the change"))
        fixture.model.handleAgentRunLifecycleEvent(.completed(
            runID: runID,
            result: AgentRunResult(stopReason: .endTurn)))

        fixture.model.deleteAgentRun()
        fixture.model.handleAgentRunLifecycleEvent(.event(
            runID: runID,
            event: .agentMessageDelta(messageID: "late", text: "Do not restore")))

        #expect(fixture.model.agentRunSnapshot == nil)
        #expect(panel.hidden == [runID])
    }

    @MainActor @Test func agentLifecycle_WhenEventIsStale_IgnoresIt() throws {
        let profile = try makeAgentProfile(displayName: "Codex")
        let fixture = try Fixture(profiles: [profile])
        let runID = UUID()
        fixture.model.handleAgentRunLifecycleEvent(.started(
            runID: runID,
            profile: profile,
            prompt: "Current"))

        fixture.model.handleAgentRunLifecycleEvent(.event(
            runID: UUID(),
            event: .agentMessageDelta(messageID: nil, text: "stale")))

        #expect(fixture.model.agentRunSnapshot?.output == "")
    }

    @MainActor @Test func agentLifecycle_WhenNoticeArrives_PublishesItInCurrentRun() throws {
        let profile = try makeAgentProfile(displayName: "Codex")
        let fixture = try Fixture(profiles: [profile])
        let runID = UUID()
        fixture.model.handleAgentRunLifecycleEvent(.started(
            runID: runID,
            profile: profile,
            prompt: "Current"))

        fixture.model.handleAgentRunLifecycleEvent(.notice(
            runID: runID,
            message: "Wait for the agent."))

        #expect(fixture.model.agentRunSnapshot?.notices == ["Wait for the agent."])
    }

    @MainActor @Test func agentConversation_WhenSpeechIsPartial_ShowsLiveFollowUpText() async throws {
        let profile = try makeAgentProfile(displayName: "Codex")
        let fixture = try Fixture(profiles: [profile])
        await fixture.model.start()
        fixture.speech.emit("Codex explain this", isFinal: true)
        await waitUntil {
            fixture.model.agentRunSnapshot?.phase == .listening
                && fixture.speech.mode == .conversation
        }

        fixture.speech.emit("also check the tests")

        #expect(fixture.model.agentRunSnapshot?.voiceInput == "also check the tests")
    }

    @MainActor @Test func agentConversation_WhenAgentReplies_ReadsRenderedReplyWithoutUsingTestAudio() async throws {
        let profile = try makeAgentProfile(displayName: "Codex")
        let runner = AppModelAgentRunnerSpy(events: [
            .agentMessageDelta(messageID: "answer", text: "**All done**"),
        ])
        let audio = AppModelAgentConversationAudioSpy()
        let fixture = try Fixture(
            profiles: [profile],
            agentRunner: runner,
            agentConversationAudioPlayer: audio)
        await fixture.model.start()

        fixture.speech.emit("Codex check this", isFinal: true)
        await waitUntil { audio.spoken.count == 1 }

        #expect(audio.spoken.first?.text == "All done")
        #expect(audio.spoken.first?.localeID == fixture.preferences.localeID)
        #expect(fixture.model.agentRunSnapshot?.phase == .listening)
    }

    @MainActor @Test func saveSettings_WhenConversationAudioChanges_PersistsOnlyOnSave() async throws {
        let credentials = AgentSpeechCredentialStoreSpy(apiKey: "saved-key")
        let fixture = try Fixture(agentSpeechCredentialStore: credentials)
        fixture.model.readsAgentRepliesAloud = false
        fixture.model.playsAgentWorkingSound = false
        fixture.model.agentSpeechProvider = .elevenLabs
        fixture.model.elevenLabsVoiceID = "voice-123"
        fixture.model.elevenLabsAPIKey = "new-key"

        #expect(fixture.preferences.readsAgentRepliesAloud)
        #expect(fixture.preferences.playsAgentWorkingSound)
        #expect(fixture.preferences.agentSpeechProvider == .system)
        #expect(credentials.apiKey == "saved-key")

        #expect(await fixture.model.saveSettings())
        #expect(!fixture.preferences.readsAgentRepliesAloud)
        #expect(!fixture.preferences.playsAgentWorkingSound)
        #expect(fixture.preferences.agentSpeechProvider == .elevenLabs)
        #expect(fixture.preferences.elevenLabsVoiceID == "voice-123")
        #expect(credentials.apiKey == "new-key")
    }

    @MainActor @Test func saveSettings_WhenElevenLabsKeyIsEmpty_PreservesSavedSpeechSettings()
        async throws
    {
        let credentials = AgentSpeechCredentialStoreSpy(apiKey: "saved-key")
        let fixture = try Fixture(agentSpeechCredentialStore: credentials)
        fixture.model.agentSpeechProvider = .elevenLabs
        fixture.model.elevenLabsAPIKey = "   "

        #expect(!(await fixture.model.saveSettings()))
        #expect(fixture.preferences.agentSpeechProvider == .system)
        #expect(credentials.apiKey == "saved-key")
        #expect(fixture.model.settingsError == "ElevenLabs requires an API key.")
    }

    @MainActor
    private struct Fixture {
        let preferences: AppPreferences
        let shortcut = ShortcutSpy()
        let speech = AppModelSpeechSessionSpy()
        let agentRunPanel: AppModelAgentPanelSpy
        let model: AppModel

        init(
            profiles: [WakeProfile]? = nil,
            agentRunner: any AgentHarnessRunning = AppModelAgentRunnerSpy(),
            agentRunPanel: AppModelAgentPanelSpy = AppModelAgentPanelSpy(),
            agentConversationAudioPlayer: any AgentConversationAudioPlaying =
                SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: any AgentSpeechCredentialStoring =
                AgentSpeechCredentialStoreSpy(),
            isExecutableFile: @escaping @MainActor (String) -> Bool = { path in
                FileManager.default.isExecutableFile(atPath: path)
            },
            isDirectory: @escaping @MainActor (String) -> Bool = { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }) throws
        {
            let suite = "VoiceActivationAppModelTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            preferences = AppPreferences(defaults: defaults)
            self.agentRunPanel = agentRunPanel
            if let profiles {
                preferences.wakeProfiles = profiles
            }
            model = AppModel(
                preferences: preferences,
                recordingOverlay: AppModelOverlayStub(),
                agentRunPanel: agentRunPanel,
                shortcut: shortcut,
                speechSession: speech,
                agentRunner: agentRunner,
                permissionRequest: { true },
                soundPlayer: SilentCaptureSoundPlayer(),
                agentConversationAudioPlayer: agentConversationAudioPlayer,
                agentSpeechCredentialStore: agentSpeechCredentialStore,
                isExecutableFile: isExecutableFile,
                isDirectory: isDirectory,
                startsAutomatically: false)
        }
    }

    private func makeAgentProfile(
        id: UUID = UUID(),
        displayName: String = "Custom agent",
        executablePath: String = "/agents/custom",
        workingDirectory: String = "/Users/test/project",
        pushToTalkHotKey: PushToTalkHotKey? = nil) throws -> WakeProfile
    {
        let configuration = try AgentHarnessConfiguration(
            preset: .custom,
            displayName: displayName,
            executablePath: executablePath,
            arguments: ["--stdio", "two words"],
            workingDirectory: workingDirectory,
            permissionPolicy: .ask)
        return try WakeProfile(
            id: id,
            wakePhrase: displayName,
            action: .agent(configuration),
            accent: .purple,
            pushToTalkHotKey: pushToTalkHotKey)
    }
}

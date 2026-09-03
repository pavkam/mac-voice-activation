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

    func show(transcript: String, accent: WakeProfileAccent) {}
    func hide() {}
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

    @MainActor
    private struct Fixture {
        let preferences: AppPreferences
        let shortcut = ShortcutSpy()
        let speech = AppModelSpeechSessionSpy()
        let model: AppModel

        init(
            profiles: [WakeProfile]? = nil,
            agentRunner: any AgentHarnessRunning = AppModelAgentRunnerSpy(),
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
            if let profiles {
                preferences.wakeProfiles = profiles
            }
            model = AppModel(
                preferences: preferences,
                recordingOverlay: AppModelOverlayStub(),
                shortcut: shortcut,
                speechSession: speech,
                agentRunner: agentRunner,
                permissionRequest: { true },
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

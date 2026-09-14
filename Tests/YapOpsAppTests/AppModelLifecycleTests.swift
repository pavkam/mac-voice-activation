// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import YapOpsApp
@testable import YapOpsCore

@MainActor
private final class ControlledShutdownArtifactOpener: AgentArtifactOpening {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isShutdownComplete = false
    private(set) var shutdownStarted = false

    func begin(runID _: UUID) {}
    func open(runID _: UUID, artifact _: AgentArtifactPresentation) {}
    func reveal(runID _: UUID, artifact _: AgentArtifactPresentation) {}
    func discard(runID _: UUID) {}

    func shutdown() async {
        shutdownStarted = true
        guard !isShutdownComplete else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func completeShutdown() {
        isShutdownComplete = true
        continuation?.resume()
        continuation = nil
    }
}


extension AppModelTests {
    @MainActor @Test func permissionRequestGate_WhenAwaitingRegistration_CompletesAfterRequestRegisters()
        async
    {
        let permission = PermissionRequestGate()
        let request = Task { @MainActor in await permission.request() }

        await permission.waitUntilWaiting()

        #expect(permission.isWaiting)
        permission.resolve(true)
        #expect(await request.value)
    }

    @MainActor @Test func togglePassiveListening_WhenProfilesDiffer_PausesWithoutChangingProfiles()
        throws
    {
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
        let suite = InMemoryDefaults.makeSuiteName("YapOpsResumeAllTests")
        let defaults = try #require(InMemoryDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        preferences.passiveEnabled = false
        let permission = PermissionRequestGate()
        let speech = AppModelSpeechSessionSpy()
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
            agentRunPanel: AppModelAgentPanelSpy(),
            shortcut: ShortcutSpy(),
            speechSession: speech,
            permissionRequest: { await permission.request() },
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
            startsAutomatically: false)

        await model.start()
        model.togglePassiveListening()
        await permission.waitUntilWaiting()
        permission.resolve(true)
        await speech.waitUntilStarted()

        #expect(model.passiveEnabled)
        #expect(preferences.passiveEnabled)
        #expect(model.activeWakeProfiles.map(\.isEnabled) == [true, false])
    }

    @MainActor @Test func start_WhenPassiveListeningIsEnabled_WiresAndStartsDependencies()
        async throws
    {
        let suite = InMemoryDefaults.makeSuiteName("YapOpsStartupTests")
        let defaults = try #require(InMemoryDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        let speech = AppModelSpeechSessionSpy()
        let shortcut = ShortcutSpy()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            agentRunPanel: AppModelAgentPanelSpy(),
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
        let suite = InMemoryDefaults.makeSuiteName("YapOpsStartupIdempotencyTests")
        let defaults = try #require(InMemoryDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        let speech = AppModelSpeechSessionSpy()
        let shortcut = ShortcutSpy()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            agentRunPanel: AppModelAgentPanelSpy(),
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

    @MainActor @Test func start_WhenCalledFromBackground_RequestsPermissionAtUserPriority()
        async throws
    {
        let suite = InMemoryDefaults.makeSuiteName("YapOpsStartupPriorityTests")
        let defaults = try #require(InMemoryDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let priorities = PermissionPriorityRecorder()
        let model = AppModel(
            preferences: AppPreferences(defaults: defaults),
            recordingOverlay: AppModelOverlayStub(),
            agentRunPanel: AppModelAgentPanelSpy(),
            shortcut: ShortcutSpy(),
            speechSession: AppModelSpeechSessionSpy(),
            permissionRequest: {
                priorities.recordCurrentPriority()
                return true
            },
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
            startsAutomatically: false)

        _ = await Task.detached(priority: .background) {
            await model.start()
        }.value

        let priority = try #require(priorities.priorities.first)
        #expect(priority.rawValue >= TaskPriority.userInitiated.rawValue)
        await model.shutdown()
    }

    @MainActor @Test func passiveListening_WhenDisabledDuringPermissionRequest_StaysOff()
        async throws
    {
        let suite = InMemoryDefaults.makeSuiteName("YapOpsPermissionRaceTests")
        let defaults = try #require(InMemoryDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        preferences.passiveEnabled = false
        let speech = AppModelSpeechSessionSpy()
        let permission = PermissionRequestGate()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            agentRunPanel: AppModelAgentPanelSpy(),
            shortcut: ShortcutSpy(),
            speechSession: speech,
            permissionRequest: { await permission.request() },
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
            startsAutomatically: false)

        #expect(await model.start())
        model.setPassiveEnabled(true)
        await permission.waitUntilWaiting()
        #expect(permission.isWaiting)
        model.setPassiveEnabled(false)
        permission.resolve(true)
        await permission.waitUntilCompletionCount(1)

        #expect(!model.passiveEnabled)
        #expect(!preferences.passiveEnabled)
        #expect(speech.startCount == 0)
    }

    @MainActor @Test func passiveListening_WhenDisabledBeforePermissionDenial_DoesNotShowFailure()
        async throws
    {
        let suite = InMemoryDefaults.makeSuiteName("YapOpsLatePermissionDenialTests")
        let defaults = try #require(InMemoryDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        preferences.passiveEnabled = false
        let permission = PermissionRequestGate()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            agentRunPanel: AppModelAgentPanelSpy(),
            shortcut: ShortcutSpy(),
            speechSession: AppModelSpeechSessionSpy(),
            permissionRequest: { await permission.request() },
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
            startsAutomatically: false)

        #expect(await model.start())
        model.setPassiveEnabled(true)
        await permission.waitUntilWaiting()
        model.setPassiveEnabled(false)
        permission.resolve(false)
        await permission.waitUntilCompletionCount(1)

        #expect(model.state == .disabled)
    }

    @MainActor @Test func passiveListening_WhenSettingDoesNotChange_DoesNotRequestPermissions()
        async throws
    {
        let suite = InMemoryDefaults.makeSuiteName("YapOpsIdempotentToggleTests")
        let defaults = try #require(InMemoryDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        let permission = PermissionRequestGate()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            agentRunPanel: AppModelAgentPanelSpy(),
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

    @MainActor @Test
    func pushToTalk_WhenStartupIsNotReady_DoesNotStartAnotherPermissionRequest() async throws {
        let suite = InMemoryDefaults.makeSuiteName("YapOpsPermissionCoalescingTests")
        let defaults = try #require(InMemoryDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        let permission = PermissionRequestGate()
        let shortcut = ShortcutSpy()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            agentRunPanel: AppModelAgentPanelSpy(),
            shortcut: shortcut,
            speechSession: AppModelSpeechSessionSpy(),
            permissionRequest: { await permission.request() },
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
            startsAutomatically: false)
        let startup = Task { @MainActor in await model.start() }
        await permission.waitUntilWaiting()
        #expect(!shortcut.startedProfiles.isEmpty)
        let profileID = try #require(shortcut.startedProfiles.first?.first?.id)

        shortcut.press(profileID)

        #expect(permission.requestCount == 1)
        #expect(model.heldHotKeyProfileID == nil)
        permission.resolve(true)
        #expect(await startup.value)
    }

    @MainActor @Test func shutdown_WhenStartupPermissionCompletesLate_DoesNotRestartListening()
        async throws
    {
        let suite = InMemoryDefaults.makeSuiteName("YapOpsShutdownPermissionTests")
        let defaults = try #require(InMemoryDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        let permission = PermissionRequestGate()
        let speech = AppModelSpeechSessionSpy()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            agentRunPanel: AppModelAgentPanelSpy(),
            shortcut: ShortcutSpy(),
            speechSession: speech,
            permissionRequest: { await permission.request() },
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
            startsAutomatically: false)
        let startup = Task { @MainActor in await model.start() }
        await permission.waitUntilWaiting()

        await model.shutdown()
        permission.resolve(true)
        _ = await startup.value

        #expect(speech.startCount == 0)
        #expect(model.state == .disabled)
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func shutdown_WhenCalledConcurrently_AllCallersAwaitArtifactCleanup()
        async throws
    {
        @MainActor func waitForReadiness(_ condition: () -> Bool) async throws {
            while !condition() {
                try await Task.sleep(for: .milliseconds(1))
            }
        }

        let suite = InMemoryDefaults.makeSuiteName("YapOpsConcurrentShutdownTests")
        let defaults = try #require(InMemoryDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let opener = ControlledShutdownArtifactOpener()
        defer { opener.completeShutdown() }
        let model = AppModel(
            preferences: AppPreferences(defaults: defaults),
            recordingOverlay: AppModelOverlayStub(),
            agentRunPanel: AppModelAgentPanelSpy(),
            artifactOpener: opener,
            shortcut: ShortcutSpy(),
            speechSession: AppModelSpeechSessionSpy(),
            permissionRequest: { true },
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
            startsAutomatically: false)
        var secondFinished = false
        let first = Task { @MainActor in await model.shutdown() }
        try await waitForReadiness { opener.shutdownStarted }

        let second = Task { @MainActor in
            await model.shutdown()
            secondFinished = true
        }
        try await waitForReadiness { model.shutdownWaiters.count == 1 }
        #expect(!secondFinished)

        opener.completeShutdown()
        await first.value
        await second.value

        #expect(secondFinished)
        #expect(model.isShutdownComplete)
    }

    @MainActor @Test func start_WhenPassiveDisabledDuringPermissionRequest_StaysOff() async throws {
        let suite = InMemoryDefaults.makeSuiteName("YapOpsStartupPausePermissionTests")
        let defaults = try #require(InMemoryDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        let permission = PermissionRequestGate()
        let speech = AppModelSpeechSessionSpy()
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: AppModelOverlayStub(),
            agentRunPanel: AppModelAgentPanelSpy(),
            shortcut: ShortcutSpy(),
            speechSession: speech,
            permissionRequest: { await permission.request() },
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
            startsAutomatically: false)
        let startup = Task { @MainActor in await model.start() }
        await permission.waitUntilWaiting()

        model.setPassiveEnabled(false)
        permission.resolve(true)
        _ = await startup.value

        #expect(!model.passiveEnabled)
        #expect(speech.startCount == 0)
        #expect(model.state == .disabled)
    }

    @MainActor @Test func pushToTalk_WhenHeldProfileChangesDuringPermission_UsesNewestBinding()
        async throws
    {
        let suite = InMemoryDefaults.makeSuiteName("YapOpsHotKeyPermissionRaceTests")
        let defaults = try #require(InMemoryDefaults(suiteName: suite))
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
            agentRunPanel: AppModelAgentPanelSpy(),
            shortcut: shortcut,
            speechSession: speech,
            permissionRequest: { await permission.request() },
            soundPlayer: SilentCaptureSoundPlayer(),
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
            startsAutomatically: false)
        await model.start()

        shortcut.press(firstProfile.id)
        await permission.waitUntilWaiting()
        shortcut.release(firstProfile.id)
        shortcut.press(secondProfile.id)
        permission.resolve(true)
        await waitUntil { speech.mode == .pushToTalk }

        #expect(overlay.shownAccents.last == .purple)
        shortcut.release(secondProfile.id)
    }

}

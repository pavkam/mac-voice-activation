// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import VoiceActivationApp
@testable import VoiceActivationCore


extension AppModelTests {
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

    @MainActor @Test func start_WhenPassiveListeningIsEnabled_WiresAndStartsDependencies()
        async throws
    {
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

    @MainActor @Test func start_WhenCalledFromBackground_RequestsPermissionAtUserPriority()
        async throws
    {
        let suite = "VoiceActivationStartupPriorityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let priorities = PermissionPriorityRecorder()
        let model = AppModel(
            preferences: AppPreferences(defaults: defaults),
            recordingOverlay: AppModelOverlayStub(),
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

        await Task.detached(priority: .background) {
            await model.start()
        }.value

        let priority = try #require(priorities.priorities.first)
        #expect(priority.rawValue >= TaskPriority.userInitiated.rawValue)
        model.shutdown()
    }

    @MainActor @Test func passiveListening_WhenDisabledDuringPermissionRequest_StaysOff()
        async throws
    {
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

    @MainActor @Test func passiveListening_WhenDisabledBeforePermissionDenial_DoesNotShowFailure()
        async throws
    {
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

    @MainActor @Test func passiveListening_WhenSettingDoesNotChange_DoesNotRequestPermissions()
        async throws
    {
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

}

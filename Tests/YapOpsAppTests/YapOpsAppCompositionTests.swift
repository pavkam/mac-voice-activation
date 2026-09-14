// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Testing

@testable import YapOpsApp
@testable import YapOpsCore

extension AppModelTests {
    @MainActor @Test
    func compositionStartup_WhenReconciliationSuspends_BlocksExternalEffectsUntilReady()
        async throws
    {
        let profile = try makeAgentProfile()
        let store = AppModelContinuityStoreSpy()
        await store.delayReconciliation()
        let preferences = try compositionPreferences(profiles: [profile], passiveEnabled: false)
        let notificationCenter = NotificationCenter()
        let access = MacContextAccessSpy(status: .authorized)
        let speech = AppModelSpeechSessionSpy()
        let shortcut = ShortcutSpy()
        let permission = PermissionRequestGate()
        let credentials = AgentSpeechCredentialStoreSpy(apiKey: "startup-key")
        let catalog = AppModelElevenLabsVoiceCatalogSpy(voices: [])
        let preview = AppModelTextToSpeechVoicePreviewSpy()
        let composition = YapOpsAppComposition.make(
            continuityStore: store,
            activationMonitor: ApplicationActivationMonitor(
                notificationCenter: notificationCenter),
            makeAgentRunner: { _ in AppModelAgentRunnerSpy() },
            makeModel: { runner, sharedStore in
                AppModel(
                    preferences: preferences,
                    recordingOverlay: AppModelOverlayStub(),
                    agentRunPanel: AppModelAgentPanelSpy(),
                    shortcut: shortcut,
                    speechSession: speech,
                    agentRunner: runner,
                    continuityStore: sharedStore,
                    permissionRequest: { await permission.request() },
                    soundPlayer: SilentCaptureSoundPlayer(),
                    agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
                    agentSpeechCredentialStore: credentials,
                    elevenLabsVoiceCatalog: catalog,
                    textToSpeechVoicePreview: preview,
                    macContextAccess: access,
                    macContextCapturer: MacContextCapturerSpy(),
                    isExecutableFile: { _ in true },
                    isDirectory: { _ in true },
                    startsAutomatically: false)
            })
        let startup = Task { @MainActor in await composition.startup.run() }
        await store.waitUntilReconciling()

        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        composition.model.setPassiveEnabled(true)
        composition.model.pushToTalkPressed(profileID: profile.id)
        composition.model.settingsDidAppear()
        composition.model.requestMacContextAccess()
        composition.model.setPushToTalkShortcutRecording(true)
        composition.model.setPushToTalkShortcutRecording(false)
        composition.model.elevenLabsAPIKey = "draft-key"
        composition.model.elevenLabsVoiceID = "draft-voice"
        let earlySave = await composition.model.saveSettings()
        await composition.model.loadTextToSpeechVoices(for: .elevenLabs)
        await composition.model.previewTextToSpeechVoice(
            TextToSpeechVoiceSelection(
                backendID: .elevenLabs,
                voiceID: "draft-voice"),
            in: .defaultVoice)
        #expect(!earlySave)
        #expect(access.statusChecks == 0)
        #expect(access.promptingChecks == 0)
        #expect(permission.requestCount == 0)
        #expect(shortcut.startedProfiles.isEmpty)
        #expect(shortcut.stopCount == 0)
        #expect(speech.startCount == 0)
        #expect(composition.model.heldHotKeyProfileID == nil)
        #expect(credentials.loadCount == 0)
        #expect(credentials.savedKeys.isEmpty)
        #expect(await catalog.requestedAPIKeys.isEmpty)
        #expect(preview.requests.isEmpty)

        await store.releaseReconciliation()
        await permission.waitUntilWaiting()
        #expect(permission.requestCount == 1)
        permission.resolve(true)
        #expect(await startup.value)
        #expect(access.statusChecks == 1)
        #expect(!shortcut.startedProfiles.isEmpty)
        #expect(speech.startCount == 1)
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(access.statusChecks == 2)

        composition.model.settingsDidAppear()
        composition.model.requestMacContextAccess()
        composition.model.setPushToTalkShortcutRecording(true)
        composition.model.setPushToTalkShortcutRecording(false)
        #expect(await composition.model.saveSettings())
        await composition.model.loadTextToSpeechVoices(for: .elevenLabs)
        await composition.model.previewTextToSpeechVoice(
            TextToSpeechVoiceSelection(
                backendID: .elevenLabs,
                voiceID: "draft-voice"),
            in: .defaultVoice)
        #expect(access.statusChecks == 3)
        #expect(access.promptingChecks == 1)
        #expect(shortcut.stopCount == 1)
        #expect(!credentials.savedKeys.isEmpty)
        #expect(await catalog.requestedAPIKeys.count == 1)
        #expect(preview.requests.map(\.selection.voiceID) == ["draft-voice"])
    }

    @MainActor
    private func compositionPreferences(
        profiles: [WakeProfile],
        passiveEnabled: Bool
    ) throws -> AppPreferences {
        let suite = InMemoryDefaults.makeSuiteName("YapOpsCompositionTests")
        let defaults = try #require(InMemoryDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        preferences.wakeProfiles = profiles
        preferences.passiveEnabled = passiveEnabled
        return preferences
    }
}

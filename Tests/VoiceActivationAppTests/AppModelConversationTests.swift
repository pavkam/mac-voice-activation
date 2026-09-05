// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import VoiceActivationApp
@testable import VoiceActivationCore


extension AppModelTests {
    @MainActor @Test func agentLifecycle_WhenRunStreams_OpensUpdatesAndRetainsPanel() throws {
        let profile = try makeAgentProfile(displayName: "Codex")
        let panel = AppModelAgentPanelSpy()
        let fixture = try Fixture(profiles: [profile], agentRunPanel: panel)
        let runID = UUID()

        fixture.model.handleAgentRunLifecycleEvent(
            .started(
                runID: runID,
                profile: profile,
                prompt: "Explain the change"))
        fixture.model.handleAgentRunLifecycleEvent(
            .event(
                runID: runID,
                event: .agentMessageDelta(messageID: nil, text: "Done")))
        fixture.model.handleAgentRunLifecycleEvent(
            .completed(
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
        fixture.model.handleAgentRunLifecycleEvent(
            .started(
                runID: runID,
                profile: profile,
                prompt: "Explain the change"))
        fixture.model.handleAgentRunLifecycleEvent(
            .completed(
                runID: runID,
                result: AgentRunResult(stopReason: .endTurn)))

        fixture.model.deleteAgentRun()
        fixture.model.handleAgentRunLifecycleEvent(
            .event(
                runID: runID,
                event: .agentMessageDelta(messageID: "late", text: "Do not restore")))

        #expect(fixture.model.agentRunSnapshot == nil)
        #expect(panel.hidden == [runID])
    }

    @MainActor @Test func agentLifecycle_WhenEventIsStale_IgnoresIt() throws {
        let profile = try makeAgentProfile(displayName: "Codex")
        let fixture = try Fixture(profiles: [profile])
        let runID = UUID()
        fixture.model.handleAgentRunLifecycleEvent(
            .started(
                runID: runID,
                profile: profile,
                prompt: "Current"))

        fixture.model.handleAgentRunLifecycleEvent(
            .event(
                runID: UUID(),
                event: .agentMessageDelta(messageID: nil, text: "stale")))

        #expect(fixture.model.agentRunSnapshot?.output == "")
    }

    @MainActor @Test func agentLifecycle_WhenNoticeArrives_PublishesItInCurrentRun() throws {
        let profile = try makeAgentProfile(displayName: "Codex")
        let fixture = try Fixture(profiles: [profile])
        let runID = UUID()
        fixture.model.handleAgentRunLifecycleEvent(
            .started(
                runID: runID,
                profile: profile,
                prompt: "Current"))

        fixture.model.handleAgentRunLifecycleEvent(
            .notice(
                runID: runID,
                message: "Wait for the agent."))

        #expect(fixture.model.agentRunSnapshot?.notices == ["Wait for the agent."])
    }

    @MainActor @Test func agentConversation_WhenSpeechIsPartial_ShowsLiveFollowUpText() async throws
    {
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

    @MainActor @Test
    func agentConversation_WhenAgentReplies_ReadsRenderedReplyWithoutUsingTestAudio()
        async throws
    {
        let profile = try makeAgentProfile(displayName: "Codex")
        let runner = AppModelAgentRunnerSpy(events: [
            .agentMessageDelta(messageID: "answer", text: "**All done**")
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

    @MainActor @Test func saveSettings_WhenConversationAudioChanges_PersistsOnlyOnSave()
        async throws
    {
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

    @MainActor @Test
    func initialization_WhenCredentialExists_DefersReadingItUntilRuntimeStarts() async throws {
        let credentials = AgentSpeechCredentialStoreSpy(apiKey: "saved-key")
        let fixture = try Fixture(agentSpeechCredentialStore: credentials)

        #expect(credentials.loadCount == 0)
        #expect(fixture.model.elevenLabsAPIKey.isEmpty)

        await fixture.model.start()
        await waitUntil { credentials.loadCount == 1 }
        await waitUntil { fixture.model.elevenLabsAPIKey == "saved-key" }
    }

    @MainActor @Test func loadElevenLabsVoices_WhenAPIKeyIsValid_SelectsFirstVoice() async throws {
        let voices = [
            ElevenLabsVoice(
                id: "voice-1",
                name: "Alexandra",
                category: "premade",
                description: "Warm"),
            ElevenLabsVoice(
                id: "voice-2",
                name: "Morgan",
                category: nil,
                description: nil),
        ]
        let catalog = AppModelElevenLabsVoiceCatalogSpy(voices: voices)
        let fixture = try Fixture(elevenLabsVoiceCatalog: catalog)
        fixture.model.agentSpeechProvider = .elevenLabs
        fixture.model.elevenLabsAPIKey = "catalog-key"
        fixture.model.elevenLabsVoiceID = ""

        await fixture.model.loadElevenLabsVoices()

        #expect(fixture.model.elevenLabsVoices == voices)
        #expect(fixture.model.elevenLabsVoiceID == "voice-1")
        #expect(await catalog.requestedAPIKeys == ["catalog-key"])
        #expect(!fixture.model.isLoadingElevenLabsVoices)
    }

    @MainActor @Test func previewElevenLabsVoice_WhenVoiceIsSelected_UsesDraftCredentials()
        async throws
    {
        let preview = AppModelElevenLabsVoicePreviewSpy()
        let fixture = try Fixture(elevenLabsVoicePreview: preview)
        fixture.model.agentSpeechProvider = .elevenLabs
        fixture.model.elevenLabsAPIKey = "draft-key"
        fixture.model.elevenLabsVoiceID = "voice-42"

        await fixture.model.previewElevenLabsVoice()

        #expect(preview.requests.count == 1)
        #expect(preview.requests.first?.apiKey == "draft-key")
        #expect(preview.requests.first?.voiceID == "voice-42")
        #expect(!fixture.model.isPreviewingElevenLabsVoice)
    }

    @MainActor @Test func agentPermission_WhenUserSaysAllowAll_ResolvesAndCollapsesPrompt()
        async throws
    {
        let profile = try makeAgentProfile(displayName: "Codex")
        let runner = AppModelPermissionAgentRunnerSpy()
        let fixture = try Fixture(profiles: [profile], agentRunner: runner)
        await fixture.model.start()
        fixture.speech.emit("Codex edit my settings", isFinal: true)
        await waitUntil {
            fixture.model.agentRunSnapshot?.permissions.count == 1
                && fixture.speech.mode == .conversation
        }

        fixture.speech.emit("allow all", isFinal: true)
        await waitUntil { await runner.recordedResolutions().count == 1 }

        let resolution = try #require(await runner.recordedResolutions().first)
        #expect(resolution.turnToken == runner.turnToken)
        #expect(resolution.requestID == runner.requestID)
        #expect(resolution.optionID == "allow-always")
        #expect(fixture.model.agentRunSnapshot?.permissions.isEmpty == true)
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

}

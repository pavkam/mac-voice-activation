// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import VoiceActivationCore

/// Owns application state and coordinates the menu, overlays, Settings, and Core services.
///
/// UI-visible state is main-actor isolated. Long-running speech, ACP, Keychain, and
/// network work crosses explicit asynchronous adapter boundaries and publishes back here.
@MainActor
@Observable
final class AppModel {
    /// The current speech and execution state rendered by the menu and recording overlay.
    var state: ActivationState = .disabled
    /// The most recently submitted transcript shown as compact history.
    var lastTranscript = ""
    /// The partial transcript currently rendered while the user speaks.
    var currentTranscript = ""
    /// Whether passive wake listening is enabled in saved application state.
    var passiveEnabled: Bool
    /// Editable Settings drafts; these do not affect runtime routing until saved.
    var wakeProfiles: [WakeProfileDraft]
    /// The last validated and applied profiles used by the coordinator and shortcuts.
    var activeWakeProfiles: [WakeProfile]
    /// The editable speech-recognition locale identifier.
    var localeID: String
    /// Whether agent response segments should be synthesized as they stream.
    var readsAgentRepliesAloud: Bool
    /// Whether quiet activity audio should fill otherwise silent agent work.
    var playsAgentWorkingSound: Bool
    /// The editable agent speech provider.
    var agentSpeechProvider: AgentSpeechProvider
    /// The editable ElevenLabs voice identifier.
    var elevenLabsVoiceID: String
    /// The in-memory ElevenLabs credential draft; persistence is Keychain-only.
    var elevenLabsAPIKey: String
    /// The latest bounded ElevenLabs voice catalog returned for Settings.
    var elevenLabsVoices: [ElevenLabsVoice] = []
    var isLoadingElevenLabsVoices = false
    var isPreviewingElevenLabsVoice = false
    var elevenLabsVoiceStatus: String?
    var elevenLabsVoiceError: String?
    var settingsError: String?
    var isSavingSettings = false
    /// The latest immutable conversation snapshot shared by menu and panel presenters.
    var agentRunSnapshot: AgentRunSnapshot?

    /// The compact status derived from runtime state rather than independently persisted flags.
    var statusPresentation: MenuStatusPresentation {
        MenuStatusPresentation.make(
            state: state,
            enabledProfileCount: activeWakeProfiles.count(where: \.isEnabled),
            isListeningEnabled: passiveEnabled,
            agentPhase: agentRunSnapshot?.phase)
    }

    @ObservationIgnored let preferences: AppPreferences
    @ObservationIgnored let speechSession: any SpeechSessionProtocol
    @ObservationIgnored let commandRunner: any CommandRunning
    @ObservationIgnored let agentRunner: any AgentHarnessRunning
    @ObservationIgnored let isExecutableFile: @MainActor (String) -> Bool
    @ObservationIgnored let isDirectory: @MainActor (String) -> Bool
    @ObservationIgnored let permissionRequest: @MainActor () async -> Bool
    @ObservationIgnored let shortcut: any PushToTalkShortcutManaging
    @ObservationIgnored let overlayPresenter: RecordingOverlayPresenter
    @ObservationIgnored let agentRunPresentation: AgentRunPresentation
    @ObservationIgnored let agentRunPanelPresenter: AgentRunPanelPresenter
    @ObservationIgnored let soundPresenter: CaptureSoundPresenter
    @ObservationIgnored let agentConversationAudioPlayer: any AgentConversationAudioPlaying
    @ObservationIgnored let agentConversationAudioPresenter: AgentConversationAudioPresenter
    @ObservationIgnored let agentSpeechCredentialStore: any AgentSpeechCredentialStoring
    @ObservationIgnored let elevenLabsVoiceCatalog: any ElevenLabsVoiceCatalogLoading
    @ObservationIgnored let elevenLabsVoicePreview: any ElevenLabsVoicePreviewing
    @ObservationIgnored let agentSpeechSettingsState: AgentSpeechSettingsState
    @ObservationIgnored let diagnostics: any VoiceActivationDiagnosticRecording
    @ObservationIgnored var elevenLabsVoiceCatalogGeneration = 0
    @ObservationIgnored var agentLifecycleSequence: UInt64 = 0
    @ObservationIgnored var started = false
    @ObservationIgnored var isShutdown = false
    @ObservationIgnored var permissionGranted = false
    @ObservationIgnored var permissionTask: Task<Bool, Never>?
    @ObservationIgnored var credentialLoadTask: Task<Void, Never>?
    @ObservationIgnored var heldHotKeyProfileID: UUID?
    @ObservationIgnored var recordingShortcut = false
    @ObservationIgnored var activeProfile: WakeProfile?
    @ObservationIgnored var pendingAgentHandoff: RecordingOverlayHandoff?
    @ObservationIgnored lazy var coordinator = VoiceActivationCoordinator(
        speechSession: speechSession,
        commandRunner: commandRunner,
        agentRunner: agentRunner,
        configuration: { [weak self] in
            guard let self else { throw ModelError.unavailable }
            return try self.savedConfiguration()
        },
        diagnostics: diagnostics)

    /// Creates the application composition root with replaceable system adapters for tests.
    ///
    /// The initializer performs no permission prompt or microphone work. When
    /// `startsAutomatically` is true, startup is scheduled only after dependencies and
    /// presentation callbacks are fully wired.
    init(
        preferences: AppPreferences = AppPreferences(),
        recordingOverlay: any RecordingOverlayDisplaying = RecordingOverlayController(),
        agentRunPanel: any AgentRunPanelDisplaying = AgentRunPanelController(),
        shortcut: any PushToTalkShortcutManaging = PushToTalkShortcut(),
        speechSession: any SpeechSessionProtocol = AppleSpeechSession(),
        commandRunner: any CommandRunning = CommandRunner(),
        agentRunner: any AgentHarnessRunning = ACPAgentRunner(),
        permissionRequest: @escaping @MainActor () async -> Bool = SpeechPermissions.request,
        soundPlayer: any CaptureSoundPlaying = SystemCaptureSoundPlayer(),
        agentConversationAudioPlayer: (any AgentConversationAudioPlaying)? = nil,
        agentSpeechCredentialStore: any AgentSpeechCredentialStoring =
            KeychainAgentSpeechCredentialStore(),
        elevenLabsVoiceCatalog: any ElevenLabsVoiceCatalogLoading =
            ElevenLabsVoiceCatalogClient(),
        elevenLabsVoicePreview: any ElevenLabsVoicePreviewing =
            ElevenLabsVoicePreviewPlayer(),
        isExecutableFile: @escaping @MainActor (String) -> Bool = AppModel.executableFileExists,
        isDirectory: @escaping @MainActor (String) -> Bool = AppModel.directoryExists,
        startsAutomatically: Bool = true,
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        let storedElevenLabsAPIKey = ""
        let agentSpeechSettingsState = AgentSpeechSettingsState(
            provider: preferences.agentSpeechProvider,
            elevenLabsAPIKey: storedElevenLabsAPIKey,
            elevenLabsVoiceID: preferences.elevenLabsVoiceID)
        let resolvedAgentConversationAudioPlayer =
            agentConversationAudioPlayer
            ?? AgentConversationAudioOrchestrator(
                speechConfiguration: {
                    agentSpeechSettingsState.configuration
                }, diagnostics: diagnostics)

        self.preferences = preferences
        self.shortcut = shortcut
        self.speechSession = speechSession
        self.commandRunner = commandRunner
        self.agentRunner = agentRunner
        self.isExecutableFile = isExecutableFile
        self.isDirectory = isDirectory
        self.permissionRequest = permissionRequest
        self.agentSpeechCredentialStore = agentSpeechCredentialStore
        self.elevenLabsVoiceCatalog = elevenLabsVoiceCatalog
        self.elevenLabsVoicePreview = elevenLabsVoicePreview
        self.agentSpeechSettingsState = agentSpeechSettingsState
        self.diagnostics = diagnostics
        overlayPresenter = RecordingOverlayPresenter(display: recordingOverlay)
        agentRunPresentation = AgentRunPresentation(diagnostics: diagnostics)
        agentRunPanelPresenter = AgentRunPanelPresenter(
            display: agentRunPanel,
            diagnostics: diagnostics)
        soundPresenter = CaptureSoundPresenter(player: soundPlayer)
        self.agentConversationAudioPlayer = resolvedAgentConversationAudioPlayer
        agentConversationAudioPresenter = AgentConversationAudioPresenter(
            player: resolvedAgentConversationAudioPlayer,
            readsReplies: { preferences.readsAgentRepliesAloud },
            playsWorkingSound: { preferences.playsAgentWorkingSound },
            localeID: { preferences.localeID },
            diagnostics: diagnostics)
        passiveEnabled = preferences.passiveEnabled
        activeWakeProfiles = preferences.wakeProfiles
        wakeProfiles = preferences.wakeProfiles.map(WakeProfileDraft.init)
        localeID = preferences.localeID
        readsAgentRepliesAloud = preferences.readsAgentRepliesAloud
        playsAgentWorkingSound = preferences.playsAgentWorkingSound
        agentSpeechProvider = preferences.agentSpeechProvider
        elevenLabsVoiceID = preferences.elevenLabsVoiceID
        elevenLabsAPIKey = storedElevenLabsAPIKey
        diagnostics.record(
            category: .app,
            event: "app_model.initialized",
            fields: [
                "profile_count": String(activeWakeProfiles.count),
                "enabled_profile_count": String(activeWakeProfiles.count(where: \.isEnabled)),
                "passive_enabled": String(passiveEnabled),
                "speech_provider": agentSpeechProvider.rawValue,
                "cloud_api_configured": String(!storedElevenLabsAPIKey.isEmpty),
                "starts_automatically": String(startsAutomatically),
            ])
        overlayPresenter.onCancel = { [weak self] in
            self?.cancelCapture()
        }
        agentRunPresentation.onPublication = { [weak self] snapshot in
            self?.publishAgentRun(snapshot)
        }
        agentRunPanelPresenter.onCancel = { [weak self] runID in
            self?.cancelAgentRun(runID: runID)
        }
        agentRunPanelPresenter.onEndConversation = { [weak self] runID in
            self?.endAgentConversation(runID: runID)
        }
        agentRunPanelPresenter.onPermission = { [weak self] runID, key, optionID in
            self?.resolveAgentPermission(
                runID: runID,
                key: key,
                optionID: optionID)
        }
        agentRunPanelPresenter.onClose = { [weak self] runID in
            self?.agentRunPresentation.close(runID: runID)
        }
        agentRunPanelPresenter.onDelete = { [weak self] runID in
            guard let self, self.agentRunSnapshot?.runID == runID else { return }
            self.agentRunPresentation.discard(runID: runID)
            self.agentRunSnapshot = nil
        }
        resolvedAgentConversationAudioPlayer.onSpeakingChange = { [weak self] speaking in
            self?.diagnostics.record(
                category: .audio,
                event: "app_model.speech_audibility_received",
                fields: ["audible": String(speaking)])
            self?.coordinator.setAgentSpeechOutputActive(speaking)
        }

        if startsAutomatically {
            Task(priority: .userInitiated) { @MainActor [weak self] in
                await self?.start()
            }
        }
    }

    /// Applies a user-requested passive-listening state after required permission checks.
    func setPassiveEnabled(_ enabled: Bool) {
        diagnostics.record(
            category: .ui,
            event: "app_model.passive_toggle_requested",
            fields: ["enabled": String(enabled)])
        guard !isShutdown else {
            diagnostics.record(
                category: .ui,
                event: "app_model.passive_toggle_ignored",
                fields: ["reason": "shutdown"])
            return
        }
        guard passiveEnabled != enabled else {
            diagnostics.record(
                category: .ui,
                event: "app_model.passive_toggle_ignored",
                fields: ["reason": "unchanged"])
            return
        }
        passiveEnabled = enabled
        preferences.passiveEnabled = enabled
        if enabled {
            Task(priority: .userInitiated) { @MainActor [weak self] in
                guard let self, self.passiveEnabled else { return }
                let permissionGranted = await self.ensurePermissions()
                guard self.passiveEnabled else {
                    self.state = .disabled
                    return
                }
                guard permissionGranted else { return }
                self.coordinator.setPassiveEnabled(true)
            }
        } else {
            coordinator.setPassiveEnabled(false)
        }
    }

    /// Toggles passive listening from the menu without changing individual profile states.
    func togglePassiveListening() {
        setPassiveEnabled(!passiveEnabled)
    }

    /// Loads the cloud voice catalog using the current in-memory credential draft.
    func loadElevenLabsVoices() async {
        elevenLabsVoiceCatalogGeneration &+= 1
        let generation = elevenLabsVoiceCatalogGeneration
        let apiKey = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        diagnostics.record(
            category: .settings,
            event: "app_model.voice_catalog_requested",
            fields: [
                "generation": String(generation),
                "provider": agentSpeechProvider.rawValue,
                "cloud_api_configured": String(!apiKey.isEmpty),
            ])

        guard agentSpeechProvider == .elevenLabs, !apiKey.isEmpty else {
            elevenLabsVoices = []
            isLoadingElevenLabsVoices = false
            elevenLabsVoiceStatus = nil
            elevenLabsVoiceError = nil
            diagnostics.record(
                category: .settings,
                event: "app_model.voice_catalog_ignored",
                fields: ["reason": "cloud_provider_not_configured"])
            return
        }

        isLoadingElevenLabsVoices = true
        elevenLabsVoiceStatus = nil
        elevenLabsVoiceError = nil
        do {
            let voices = try await elevenLabsVoiceCatalog.voices(apiKey: apiKey)
            try Task.checkCancellation()
            guard generation == elevenLabsVoiceCatalogGeneration else { return }
            elevenLabsVoices = voices
            if elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                elevenLabsVoiceID = voices.first?.id ?? ""
            }
            elevenLabsVoiceStatus =
                voices.isEmpty
                ? "No voices were returned. You can still enter a voice ID manually."
                : "\(voices.count) voice\(voices.count == 1 ? "" : "s") available."
            diagnostics.record(
                category: .settings,
                event: "app_model.voice_catalog_loaded",
                fields: [
                    "generation": String(generation),
                    "voice_count": String(voices.count),
                ])
        } catch is CancellationError {
            // A newer catalog request owns the visible state.
            diagnostics.record(
                category: .settings,
                event: "app_model.voice_catalog_cancelled",
                fields: ["generation": String(generation)])
        } catch {
            guard generation == elevenLabsVoiceCatalogGeneration else { return }
            elevenLabsVoices = []
            elevenLabsVoiceError = error.localizedDescription
            diagnostics.record(
                category: .settings,
                event: "app_model.voice_catalog_failed",
                level: .error,
                fields: [
                    "generation": String(generation),
                    "error_type": String(describing: type(of: error)),
                ])
        }
        if generation == elevenLabsVoiceCatalogGeneration {
            isLoadingElevenLabsVoices = false
        }
    }

    /// Synthesizes and plays a short sample for the currently selected cloud voice.
    func previewElevenLabsVoice() async {
        diagnostics.record(category: .ui, event: "app_model.voice_preview_requested")
        guard !isPreviewingElevenLabsVoice else {
            diagnostics.record(
                category: .ui,
                event: "app_model.voice_preview_ignored",
                fields: ["reason": "already_previewing"])
            return
        }
        let apiKey = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceID = elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            elevenLabsVoiceError = "Enter an ElevenLabs API key to test a voice."
            diagnostics.record(
                category: .ui,
                event: "app_model.voice_preview_rejected",
                fields: ["reason": "api_key_missing"])
            return
        }
        guard !voiceID.isEmpty else {
            elevenLabsVoiceError = "Select an ElevenLabs voice to test it."
            diagnostics.record(
                category: .ui,
                event: "app_model.voice_preview_rejected",
                fields: ["reason": "voice_missing"])
            return
        }

        isPreviewingElevenLabsVoice = true
        elevenLabsVoiceStatus = nil
        elevenLabsVoiceError = nil
        defer { isPreviewingElevenLabsVoice = false }
        do {
            try await elevenLabsVoicePreview.play(apiKey: apiKey, voiceID: voiceID)
            elevenLabsVoiceStatus = "Voice preview finished."
            diagnostics.record(category: .ui, event: "app_model.voice_preview_finished")
        } catch is CancellationError {
            elevenLabsVoicePreview.stop()
            diagnostics.record(category: .ui, event: "app_model.voice_preview_cancelled")
        } catch {
            elevenLabsVoiceError = error.localizedDescription
            diagnostics.record(
                category: .ui,
                event: "app_model.voice_preview_failed",
                level: .error,
                fields: ["error_type": String(describing: type(of: error))])
        }
    }

    /// Applies one profile's passive-listening toggle immediately and persists it safely.
    func setWakeProfileEnabled(_ id: UUID, enabled: Bool) {
        guard let activeIndex = activeWakeProfiles.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard activeWakeProfiles[activeIndex].isEnabled != enabled else { return }

        diagnostics.record(
            category: .ui,
            event: "app_model.profile_enabled_changed",
            fields: [
                "profile_id": id.uuidString,
                "enabled": String(enabled),
            ])

        activeWakeProfiles[activeIndex].isEnabled = enabled
        preferences.wakeProfiles = activeWakeProfiles
        if let draftIndex = wakeProfiles.firstIndex(where: { $0.id == id }) {
            wakeProfiles[draftIndex].isEnabled = enabled
        }
        coordinator.refreshConfiguration()
    }

    @discardableResult
    /// Validates all drafts, atomically applies runtime changes, and persists valid settings.
    ///
    /// - Returns: `true` when Settings may close; otherwise `settingsError` explains the failure.
    func saveSettings() async -> Bool {
        guard !isSavingSettings else {
            diagnostics.record(
                category: .settings,
                event: "settings.save_ignored",
                fields: ["reason": "already_saving"])
            return false
        }
        isSavingSettings = true
        defer { isSavingSettings = false }
        diagnostics.record(
            category: .settings,
            event: "settings.save_started",
            fields: [
                "profile_count": String(wakeProfiles.count),
                "speech_provider": agentSpeechProvider.rawValue,
                "reads_replies": String(readsAgentRepliesAloud),
                "plays_working_sound": String(playsAgentWorkingSound),
            ])

        let profiles: [WakeProfile]
        do {
            profiles = try wakeProfiles.map { try $0.validatedProfile() }
            try WakeProfileCollectionValidator.validate(profiles)
            try validateFileSystem(profiles)
            try validateAgentSpeechSettings()
        } catch {
            settingsError = error.localizedDescription
            diagnostics.record(
                category: .settings,
                event: "settings.save_failed",
                level: .error,
                fields: [
                    "stage": "validation",
                    "error_type": String(describing: type(of: error)),
                ])
            return false
        }

        do {
            try registerShortcuts(profiles)
        } catch {
            settingsError = error.localizedDescription
            diagnostics.record(
                category: .settings,
                event: "settings.save_failed",
                level: .error,
                fields: [
                    "stage": "hot_key_registration",
                    "error_type": String(describing: type(of: error)),
                ])
            return false
        }

        let normalizedAPIKey = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        credentialLoadTask?.cancel()
        do {
            try agentSpeechCredentialStore.saveElevenLabsAPIKey(
                normalizedAPIKey.isEmpty ? nil : normalizedAPIKey)
        } catch {
            try? registerShortcuts(activeWakeProfiles)
            settingsError = error.localizedDescription
            diagnostics.record(
                category: .settings,
                event: "settings.save_failed",
                level: .error,
                fields: [
                    "stage": "credential_storage",
                    "error_type": String(describing: type(of: error)),
                ])
            return false
        }

        let profileIDsToReset = agentProfileIDsToReset(
            oldProfiles: activeWakeProfiles,
            newProfiles: profiles)
        preferences.wakeProfiles = profiles
        preferences.localeID = localeID
        preferences.readsAgentRepliesAloud = readsAgentRepliesAloud
        preferences.playsAgentWorkingSound = playsAgentWorkingSound
        preferences.agentSpeechProvider = agentSpeechProvider
        preferences.elevenLabsVoiceID = elevenLabsVoiceID
        elevenLabsAPIKey = normalizedAPIKey
        elevenLabsVoiceID = preferences.elevenLabsVoiceID
        let previousSpeechConfiguration = agentSpeechSettingsState.configuration
        agentSpeechSettingsState.update(
            provider: agentSpeechProvider,
            elevenLabsAPIKey: normalizedAPIKey,
            elevenLabsVoiceID: elevenLabsVoiceID)
        if previousSpeechConfiguration != agentSpeechSettingsState.configuration {
            agentConversationAudioPlayer.stopSpeaking()
        }
        agentConversationAudioPresenter.refreshSettings()
        activeWakeProfiles = profiles
        wakeProfiles = activeWakeProfiles.map(WakeProfileDraft.init)
        localeID = preferences.localeID
        if !profileIDsToReset.isEmpty {
            await agentRunner.reset(profileIDs: profileIDsToReset)
        }
        settingsError = nil
        coordinator.refreshConfiguration()
        diagnostics.record(
            category: .settings,
            event: "settings.save_finished",
            fields: [
                "profile_count": String(profiles.count),
                "reset_agent_session_count": String(profileIDsToReset.count),
                "speech_configuration_changed": String(
                    previousSpeechConfiguration != agentSpeechSettingsState.configuration),
            ])
        return true
    }

}

extension ActivationState {
    var appModelDiagnosticName: String {
        switch self {
        case .disabled: "disabled"
        case .listening: "listening"
        case .capturing: "capturing"
        case .executing: "executing"
        case .failed: "failed"
        }
    }
}

extension AgentRunPhase {
    var appModelDiagnosticName: String {
        switch self {
        case .listening: "listening"
        case .running: "running"
        case .cancelling: "cancelling"
        case .completed: "completed"
        case .failed: "failed"
        }
    }
}

extension AgentRunLifecycleEvent {
    var appModelDiagnosticFields: [String: String] {
        switch self {
        case .started(let runID, _, let prompt):
            [
                "kind": "started", "run_id": runID.uuidString,
                "input_character_count": String(prompt.count),
            ]
        case .followUpSubmitted(let runID, let prompt):
            [
                "kind": "follow_up_submitted", "run_id": runID.uuidString,
                "input_character_count": String(prompt.count),
            ]
        case .notice(let runID, let message):
            [
                "kind": "notice", "run_id": runID.uuidString,
                "message_character_count": String(message.count),
            ]
        case .turnStarted(let runID):
            ["kind": "turn_started", "run_id": runID.uuidString]
        case .turnCancellationStarted(let runID):
            ["kind": "turn_cancellation_started", "run_id": runID.uuidString]
        case .event(let runID, let event):
            [
                "kind": "event", "run_id": runID.uuidString,
                "event_kind": AppModel.eventKind(event),
            ]
        case .turnCompleted(let runID, let result):
            [
                "kind": "turn_completed", "run_id": runID.uuidString,
                "stop_reason": result.stopReason.rawValue,
            ]
        case .turnFailed(let runID, _):
            ["kind": "turn_failed", "run_id": runID.uuidString]
        case .completed(let runID, let result):
            [
                "kind": "completed", "run_id": runID.uuidString,
                "stop_reason": result.stopReason.rawValue,
            ]
        case .failed(let runID, _):
            ["kind": "failed", "run_id": runID.uuidString]
        }
    }
}

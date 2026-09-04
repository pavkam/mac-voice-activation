// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import VoiceActivationCore

@MainActor
@Observable
final class AppModel {
    var state: ActivationState = .disabled
    var lastTranscript = ""
    var currentTranscript = ""
    var passiveEnabled: Bool
    var wakeProfiles: [WakeProfileDraft]
    private(set) var activeWakeProfiles: [WakeProfile]
    var localeID: String
    var readsAgentRepliesAloud: Bool
    var playsAgentWorkingSound: Bool
    var agentSpeechProvider: AgentSpeechProvider
    var elevenLabsVoiceID: String
    var elevenLabsAPIKey: String
    private(set) var elevenLabsVoices: [ElevenLabsVoice] = []
    private(set) var isLoadingElevenLabsVoices = false
    private(set) var isPreviewingElevenLabsVoice = false
    private(set) var elevenLabsVoiceStatus: String?
    private(set) var elevenLabsVoiceError: String?
    var settingsError: String?
    private(set) var isSavingSettings = false
    private(set) var agentRunSnapshot: AgentRunSnapshot?

    var statusPresentation: MenuStatusPresentation {
        MenuStatusPresentation.make(
            state: state,
            enabledProfileCount: activeWakeProfiles.count(where: \.isEnabled),
            isListeningEnabled: passiveEnabled,
            agentPhase: agentRunSnapshot?.phase)
    }

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let speechSession: any SpeechSessionProtocol
    @ObservationIgnored private let commandRunner: any CommandRunning
    @ObservationIgnored private let agentRunner: any AgentHarnessRunning
    @ObservationIgnored private let isExecutableFile: @MainActor (String) -> Bool
    @ObservationIgnored private let isDirectory: @MainActor (String) -> Bool
    @ObservationIgnored private let permissionRequest: @MainActor () async -> Bool
    @ObservationIgnored private let shortcut: any PushToTalkShortcutManaging
    @ObservationIgnored private let overlayPresenter: RecordingOverlayPresenter
    @ObservationIgnored private let agentRunPresentation: AgentRunPresentation
    @ObservationIgnored private let agentRunPanelPresenter: AgentRunPanelPresenter
    @ObservationIgnored private let soundPresenter: CaptureSoundPresenter
    @ObservationIgnored private let agentConversationAudioPlayer: any AgentConversationAudioPlaying
    @ObservationIgnored private let agentConversationAudioPresenter: AgentConversationAudioPresenter
    @ObservationIgnored private let agentSpeechCredentialStore: any AgentSpeechCredentialStoring
    @ObservationIgnored private let elevenLabsVoiceCatalog: any ElevenLabsVoiceCatalogLoading
    @ObservationIgnored private let elevenLabsVoicePreview: any ElevenLabsVoicePreviewing
    @ObservationIgnored private let agentSpeechSettingsState: AgentSpeechSettingsState
    @ObservationIgnored private let diagnostics: any VoiceActivationDiagnosticRecording
    @ObservationIgnored private var elevenLabsVoiceCatalogGeneration = 0
    @ObservationIgnored private var agentLifecycleSequence: UInt64 = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isShutdown = false
    @ObservationIgnored private var permissionGranted = false
    @ObservationIgnored private var permissionTask: Task<Bool, Never>?
    @ObservationIgnored private var credentialLoadTask: Task<Void, Never>?
    @ObservationIgnored private var heldHotKeyProfileID: UUID?
    @ObservationIgnored private var recordingShortcut = false
    @ObservationIgnored private var activeProfile: WakeProfile?
    @ObservationIgnored private var pendingAgentHandoff: RecordingOverlayHandoff?
    @ObservationIgnored private lazy var coordinator = VoiceActivationCoordinator(
        speechSession: speechSession,
        commandRunner: commandRunner,
        agentRunner: agentRunner,
        configuration: { [weak self] in
            guard let self else { throw ModelError.unavailable }
            return try self.savedConfiguration()
        },
        diagnostics: diagnostics)

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
            Task { @MainActor [weak self] in
                await self?.start()
            }
        }
    }

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
            Task { @MainActor [weak self] in
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

    func togglePassiveListening() {
        setPassiveEnabled(!passiveEnabled)
    }

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

    func shutdown() {
        guard !isShutdown else {
            diagnostics.record(category: .app, event: "app_model.shutdown_ignored")
            return
        }
        diagnostics.record(category: .app, event: "app_model.shutdown_started")
        isShutdown = true
        heldHotKeyProfileID = nil
        shortcut.stop()
        coordinator.stop()
        overlayPresenter.update(state: .disabled, transcript: "")
        if let runID = agentRunSnapshot?.runID {
            agentRunPanelPresenter.hide(runID: runID)
        }
        agentRunPresentation.shutdown()
        agentConversationAudioPresenter.shutdown()
        elevenLabsVoiceCatalogGeneration &+= 1
        credentialLoadTask?.cancel()
        elevenLabsVoicePreview.stop()
        diagnostics.record(category: .app, event: "app_model.shutdown_finished")
        diagnostics.flush()
    }

    func setPushToTalkHotKey(_ hotKey: PushToTalkHotKey?, for profileID: UUID) {
        guard let index = wakeProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        guard wakeProfiles[index].pushToTalkHotKey != hotKey else { return }
        wakeProfiles[index].pushToTalkHotKey = hotKey
        settingsError = nil
        diagnostics.record(
            category: .settings,
            event: "settings.hot_key_draft_changed",
            fields: [
                "profile_id": profileID.uuidString,
                "has_hot_key": String(hotKey != nil),
            ])
    }

    func setPushToTalkShortcutRecording(_ recording: Bool) {
        guard recording != recordingShortcut else { return }
        recordingShortcut = recording
        diagnostics.record(
            category: .hotKey,
            event: "hot_key.recording_changed",
            fields: ["recording": String(recording)])
        if recording {
            shortcut.stop()
            return
        }

        do {
            try registerShortcuts(activeWakeProfiles)
        } catch {
            settingsError = error.localizedDescription
            diagnostics.record(
                category: .hotKey,
                event: "hot_key.registration_restore_failed",
                level: .error,
                fields: ["error_type": String(describing: type(of: error))])
        }
    }

    func start() async {
        guard !started, !isShutdown else {
            diagnostics.record(
                category: .app,
                event: "app_model.start_ignored",
                fields: [
                    "already_started": String(started),
                    "shutdown": String(isShutdown),
                ])
            return
        }
        started = true
        diagnostics.record(category: .app, event: "app_model.start_started")
        startCredentialLoad()
        coordinator.onStateChange = { [weak self] in
            guard let self else { return }
            if $0 == .capturing {
                self.pendingAgentHandoff = nil
            } else if $0 == .executing, self.pendingAgentHandoff == nil {
                self.pendingAgentHandoff = self.overlayPresenter.takeAgentRunHandoff()
            } else if $0 != .executing {
                self.pendingAgentHandoff = nil
            }
            self.state = $0
            self.diagnostics.record(
                category: .ui,
                event: "app_model.state_published",
                fields: ["state": $0.appModelDiagnosticName])
            self.soundPresenter.update(state: $0)
            self.updateRecordingOverlay()
        }
        coordinator.onTranscriptChange = { [weak self] in self?.lastTranscript = $0 }
        coordinator.onCurrentTranscriptChange = { [weak self] in
            guard let self else { return }
            self.currentTranscript = $0
            if let snapshot = self.agentRunSnapshot, !snapshot.phase.isTerminal {
                self.agentRunPresentation.updateVoiceInput(
                    runID: snapshot.runID,
                    transcript: $0)
            }
            self.updateRecordingOverlay()
        }
        coordinator.onActiveProfileChange = { [weak self] in
            self?.activeProfile = $0
            self?.updateRecordingOverlay()
        }
        coordinator.onAgentRunEvent = { [weak self] event in
            self?.handleAgentRunLifecycleEvent(event)
        }
        coordinator.onAgentSpeechCancellation = { [weak self] in
            self?.diagnostics.record(
                category: .audio,
                event: "app_model.agent_speech_cancel_received")
            self?.agentConversationAudioPlayer.stopSpeaking()
        }
        coordinator.onAgentVoiceUtterance = { [weak self] utterance in
            self?.handleAgentVoiceUtterance(utterance) ?? false
        }
        do {
            try registerShortcuts(activeWakeProfiles)
        } catch {
            settingsError = error.localizedDescription
            diagnostics.record(
                category: .hotKey,
                event: "app_model.hot_key_start_failed",
                level: .error,
                fields: ["error_type": String(describing: type(of: error))])
        }

        guard passiveEnabled else {
            diagnostics.record(
                category: .app,
                event: "app_model.start_finished",
                fields: ["passive_listening_started": "false"])
            return
        }
        guard await ensurePermissions(), passiveEnabled, !isShutdown else {
            diagnostics.record(
                category: .app,
                event: "app_model.start_finished",
                fields: ["passive_listening_started": "false"])
            return
        }
        coordinator.setPassiveEnabled(true)
        diagnostics.record(
            category: .app,
            event: "app_model.start_finished",
            fields: ["passive_listening_started": "true"])
    }

    private func startCredentialLoad() {
        guard credentialLoadTask == nil else {
            diagnostics.record(
                category: .settings,
                event: "credential_load.ignored",
                fields: ["reason": "already_started"])
            return
        }

        let initialDraft = elevenLabsAPIKey
        diagnostics.record(category: .settings, event: "credential_load.started")
        credentialLoadTask = Task {
            @MainActor [weak self, agentSpeechCredentialStore, diagnostics] in
            do {
                let storedAPIKey = try await agentSpeechCredentialStore.loadElevenLabsAPIKey() ?? ""
                try Task.checkCancellation()
                guard let self, !self.isShutdown else { return }

                let applied = self.elevenLabsAPIKey == initialDraft
                if applied {
                    self.elevenLabsAPIKey = storedAPIKey
                    self.agentSpeechSettingsState.update(
                        provider: self.agentSpeechProvider,
                        elevenLabsAPIKey: storedAPIKey,
                        elevenLabsVoiceID: self.elevenLabsVoiceID)
                }
                diagnostics.record(
                    category: .settings,
                    event: "credential_load.finished",
                    fields: [
                        "cloud_api_configured": String(!storedAPIKey.isEmpty),
                        "applied_to_draft": String(applied),
                    ])
            } catch is CancellationError {
                diagnostics.record(category: .settings, event: "credential_load.cancelled")
            } catch {
                diagnostics.record(
                    category: .settings,
                    event: "credential_load.failed",
                    level: .error,
                    fields: ["error_type": String(describing: type(of: error))])
            }
        }
    }

    private func registerShortcuts(_ profiles: [WakeProfile]) throws {
        try shortcut.start(
            profiles: profiles,
            onPressed: { [weak self] in self?.pushToTalkPressed(profileID: $0) },
            onReleased: { [weak self] in self?.pushToTalkReleased(profileID: $0) })
    }

    private func validateFileSystem(_ profiles: [WakeProfile]) throws {
        for profile in profiles {
            switch profile.action {
            case .command(let command):
                guard isExecutableFile(command.executablePath) else {
                    throw SettingsValidationError.executableIsNotRunnable(
                        command.executablePath)
                }
            case .agent(let configuration):
                guard isExecutableFile(configuration.executablePath) else {
                    throw SettingsValidationError.agentExecutableIsNotRunnable(
                        configuration.executablePath)
                }
                guard isDirectory(configuration.workingDirectory) else {
                    throw SettingsValidationError.workingDirectoryIsNotDirectory(
                        configuration.workingDirectory)
                }
            }
        }
    }

    private func validateAgentSpeechSettings() throws {
        guard agentSpeechProvider == .elevenLabs else { return }
        guard !elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SettingsValidationError.elevenLabsAPIKeyRequired
        }
        guard !elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SettingsValidationError.elevenLabsVoiceIDRequired
        }
    }

    private func agentProfileIDsToReset(
        oldProfiles: [WakeProfile],
        newProfiles: [WakeProfile]
    ) -> Set<UUID> {
        let newProfilesByID = Dictionary(uniqueKeysWithValues: newProfiles.map { ($0.id, $0) })
        return Set(
            oldProfiles.compactMap { oldProfile in
                guard case .agent(let oldConfiguration) = oldProfile.action else { return nil }
                guard let newProfile = newProfilesByID[oldProfile.id] else { return oldProfile.id }
                switch newProfile.action {
                case .command:
                    return oldProfile.id
                case .agent(let newConfiguration):
                    return oldConfiguration == newConfiguration ? nil : oldProfile.id
                }
            })
    }

    private func pushToTalkPressed(profileID: UUID) {
        diagnostics.record(
            category: .hotKey,
            event: "app_model.push_to_talk_pressed",
            fields: ["profile_id": profileID.uuidString])
        guard !isShutdown, heldHotKeyProfileID == nil else {
            diagnostics.record(
                category: .hotKey,
                event: "app_model.push_to_talk_ignored",
                fields: ["reason": isShutdown ? "shutdown" : "another_binding_held"])
            return
        }
        heldHotKeyProfileID = profileID
        Task { @MainActor [weak self] in
            guard let self,
                await self.ensurePermissions(),
                self.heldHotKeyProfileID == profileID
            else { return }
            self.coordinator.pushToTalkPressed(profileID: profileID)
        }
    }

    private func pushToTalkReleased(profileID: UUID) {
        guard heldHotKeyProfileID == profileID else {
            diagnostics.record(
                category: .hotKey,
                event: "app_model.push_to_talk_release_ignored",
                fields: ["profile_id": profileID.uuidString])
            return
        }
        diagnostics.record(
            category: .hotKey,
            event: "app_model.push_to_talk_released",
            fields: ["profile_id": profileID.uuidString])
        heldHotKeyProfileID = nil
        coordinator.pushToTalkReleased()
    }

    func cancelCapture() {
        diagnostics.record(category: .ui, event: "app_model.capture_cancel_clicked")
        heldHotKeyProfileID = nil
        coordinator.cancelCapture()
    }

    func showAgentRun() {
        guard let runID = agentRunSnapshot?.runID else {
            diagnostics.record(
                category: .ui,
                event: "app_model.agent_run_open_ignored",
                fields: ["reason": "no_snapshot"])
            return
        }
        diagnostics.record(
            category: .ui,
            event: "app_model.agent_run_open_clicked",
            fields: ["run_id": runID.uuidString])
        agentRunPanelPresenter.show(runID: runID)
    }

    func deleteAgentRun() {
        guard let snapshot = agentRunSnapshot, snapshot.phase.isTerminal else {
            diagnostics.record(
                category: .ui,
                event: "app_model.agent_run_delete_ignored",
                fields: ["reason": "no_terminal_snapshot"])
            return
        }
        diagnostics.record(
            category: .ui,
            event: "app_model.agent_run_delete_clicked",
            fields: ["run_id": snapshot.runID.uuidString])
        agentRunPanelPresenter.delete(runID: snapshot.runID)
    }

    func cancelAgentRun(runID: UUID) {
        diagnostics.record(
            category: .ui,
            event: "app_model.stop_turn_clicked",
            fields: ["run_id": runID.uuidString])
        guard agentRunPresentation.beginCancellation(runID: runID) else {
            diagnostics.record(
                category: .ui,
                event: "app_model.stop_turn_ignored",
                fields: ["run_id": runID.uuidString])
            return
        }
        coordinator.cancelAgentRun()
    }

    func endAgentConversation(runID: UUID) {
        guard agentRunSnapshot?.runID == runID,
            agentRunSnapshot?.phase.isTerminal == false
        else {
            diagnostics.record(
                category: .ui,
                event: "app_model.end_conversation_ignored",
                fields: ["run_id": runID.uuidString])
            return
        }
        diagnostics.record(
            category: .ui,
            event: "app_model.end_conversation_clicked",
            fields: ["run_id": runID.uuidString])
        coordinator.endAgentConversation()
    }

    func resolveAgentPermission(
        runID: UUID,
        key: AgentPermissionKey,
        optionID: String
    ) {
        resolveAgentPermission(runID: runID, key: key, selectedOptionID: optionID)
    }

    private func resolveAgentPermission(
        runID: UUID,
        key: AgentPermissionKey,
        selectedOptionID: String?
    ) {
        diagnostics.record(
            category: .ui,
            event: "app_model.permission_selected",
            fields: [
                "run_id": runID.uuidString,
                "has_option": String(selectedOptionID != nil),
            ])
        guard agentRunPresentation.beginPermissionResolution(runID: runID, key: key) else {
            diagnostics.record(
                category: .ui,
                event: "app_model.permission_ignored",
                fields: ["run_id": runID.uuidString])
            return
        }
        agentConversationAudioPresenter.resumeAfterPermission(runID: runID)
        coordinator.resolveAgentPermission(
            runID: runID,
            turnToken: key.turnToken,
            requestID: key.requestID,
            optionID: selectedOptionID)
    }

    private func handleAgentVoiceUtterance(_ utterance: String) -> Bool {
        diagnostics.record(
            category: .speechRecognition,
            event: "app_model.agent_voice_utterance_received",
            fields: ["character_count": String(utterance.count)])
        guard let snapshot = agentRunSnapshot,
            !snapshot.phase.isTerminal,
            let permission = snapshot.permissions.first,
            let decision = AgentPermissionVoiceCommand.match(
                utterance,
                options: permission.options)
        else {
            diagnostics.record(
                category: .speechRecognition,
                event: "app_model.agent_voice_utterance_not_handled",
                fields: ["reason": "not_permission_command"])
            return false
        }

        switch decision {
        case .select(let optionID):
            diagnostics.record(
                category: .speechRecognition,
                event: "app_model.permission_voice_command_matched",
                fields: [
                    "run_id": snapshot.runID.uuidString,
                    "decision": "select",
                ])
            resolveAgentPermission(
                runID: snapshot.runID,
                key: permission.key,
                selectedOptionID: optionID)
        case .cancel:
            diagnostics.record(
                category: .speechRecognition,
                event: "app_model.permission_voice_command_matched",
                fields: [
                    "run_id": snapshot.runID.uuidString,
                    "decision": "cancel",
                ])
            resolveAgentPermission(
                runID: snapshot.runID,
                key: permission.key,
                selectedOptionID: nil)
        }
        return true
    }

    func handleAgentRunLifecycleEvent(_ event: AgentRunLifecycleEvent) {
        agentLifecycleSequence &+= 1
        diagnostics.record(
            category: .agent,
            event: "app_model.lifecycle_received",
            fields: event.appModelDiagnosticFields.merging([
                "lifecycle_sequence": String(agentLifecycleSequence)
            ]) { _, new in new })
        switch event {
        case .started(let runID, let profile, let prompt):
            agentRunPresentation.start(runID: runID, profile: profile, prompt: prompt)
        case .followUpSubmitted(let runID, let prompt):
            agentRunPresentation.submitFollowUp(runID: runID, prompt: prompt)
        case .notice(let runID, let message):
            agentRunPresentation.receiveNotice(runID: runID, message: message)
        case .turnStarted(let runID):
            agentRunPresentation.beginTurn(runID: runID)
        case .turnCancellationStarted(let runID):
            _ = agentRunPresentation.beginCancellation(runID: runID)
        case .event(let runID, let event):
            agentRunPresentation.receive(runID: runID, event: event)
        case .turnCompleted(let runID, let result):
            agentRunPresentation.completeTurn(runID: runID, result: result)
        case .turnFailed(let runID, let message):
            agentRunPresentation.interruptTurn(runID: runID, message: message)
        case .completed(let runID, let result):
            agentRunPresentation.complete(runID: runID, result: result)
        case .failed(let runID, let message):
            agentRunPresentation.fail(runID: runID, message: message)
        }
        agentConversationAudioPresenter.handle(event)
        diagnostics.record(
            category: .agent,
            event: "app_model.lifecycle_dispatched",
            fields: ["lifecycle_sequence": String(agentLifecycleSequence)])
    }

    private func ensurePermissions() async -> Bool {
        guard !isShutdown else {
            diagnostics.record(
                category: .app,
                event: "permissions.request_ignored",
                fields: ["reason": "shutdown"])
            return false
        }
        if permissionGranted {
            diagnostics.record(
                category: .app,
                event: "permissions.cached",
                fields: ["granted": "true"])
            return true
        }
        if let permissionTask {
            diagnostics.record(category: .app, event: "permissions.joined_pending_request")
            let granted = await permissionTask.value
            return isShutdown ? false : granted
        }

        diagnostics.record(category: .app, event: "permissions.request_started")
        let task = Task { @MainActor [permissionRequest] in
            await permissionRequest()
        }
        permissionTask = task
        let granted = await task.value
        permissionTask = nil
        guard !isShutdown else { return false }
        permissionGranted = granted
        diagnostics.record(
            category: .app,
            event: "permissions.request_finished",
            fields: ["granted": String(granted)])
        if !permissionGranted {
            state = .failed("Microphone and Speech Recognition permissions are required.")
            passiveEnabled = false
            preferences.passiveEnabled = false
        }
        return permissionGranted
    }

    private func savedConfiguration() throws -> ActivationConfiguration {
        ActivationConfiguration(
            profiles: preferences.wakeProfiles,
            localeID: preferences.localeID)
    }

    private func updateRecordingOverlay() {
        diagnostics.record(
            category: .ui,
            event: "recording_overlay.update_requested",
            level: .debug,
            fields: [
                "state": state.appModelDiagnosticName,
                "recognized_character_count": String(currentTranscript.count),
                "has_active_profile": String(activeProfile != nil),
            ])
        overlayPresenter.update(
            state: state,
            transcript: currentTranscript,
            accent: activeProfile?.accent ?? activeWakeProfiles.first?.accent ?? .blue)
    }

    private func publishAgentRun(_ snapshot: AgentRunSnapshot) {
        let beginsRun = agentRunSnapshot?.runID != snapshot.runID
        diagnostics.record(
            category: .ui,
            event: "agent_panel.snapshot_published",
            fields: [
                "run_id": snapshot.runID.uuidString,
                "begins_run": String(beginsRun),
                "phase": snapshot.phase.appModelDiagnosticName,
                "timeline_item_count": String(snapshot.timeline.count),
                "permission_count": String(snapshot.permissions.count),
                "notice_count": String(snapshot.notices.count),
            ])
        agentRunSnapshot = snapshot
        if beginsRun {
            agentRunPanelPresenter.begin(snapshot, from: pendingAgentHandoff)
            pendingAgentHandoff = nil
        } else {
            agentRunPanelPresenter.update(snapshot)
        }
    }

    nonisolated fileprivate static func eventKind(_ event: AgentRunEvent) -> String {
        switch event {
        case .connected: "connected"
        case .agentMessageDelta: "agent_message_delta"
        case .thoughtDelta: "thought_delta"
        case .toolCall: "tool_call"
        case .toolCallUpdate: "tool_call_update"
        case .plan: "plan"
        case .permissionRequested: "permission_requested"
        case .metadata: "metadata"
        case .diagnostic: "diagnostic"
        case .deliveryNotice: "delivery_notice"
        case .unknown: "unknown"
        }
    }

    private static func executableFileExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    private static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private enum SettingsValidationError: Error, LocalizedError {
        case executableIsNotRunnable(String)
        case agentExecutableIsNotRunnable(String)
        case workingDirectoryIsNotDirectory(String)
        case elevenLabsAPIKeyRequired
        case elevenLabsVoiceIDRequired

        var errorDescription: String? {
            switch self {
            case .executableIsNotRunnable(let path):
                "The executable is missing or not runnable: \(path)"
            case .agentExecutableIsNotRunnable(let path):
                "The agent executable is missing or not runnable: \(path)"
            case .workingDirectoryIsNotDirectory(let path):
                "The agent working directory is missing or is not a directory: \(path)"
            case .elevenLabsAPIKeyRequired:
                "ElevenLabs requires an API key."
            case .elevenLabsVoiceIDRequired:
                "ElevenLabs requires a voice ID."
            }
        }
    }

    private enum ModelError: Error, LocalizedError {
        case unavailable

        var errorDescription: String? {
            "Voice Activation is unavailable."
        }
    }
}

extension ActivationState {
    fileprivate var appModelDiagnosticName: String {
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
    fileprivate var appModelDiagnosticName: String {
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
    fileprivate var appModelDiagnosticFields: [String: String] {
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

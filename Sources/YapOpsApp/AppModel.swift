// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import YapOpsCore

/// Owns application state and coordinates the menu, overlays, Settings, and Core services.
///
/// UI-visible state is main-actor isolated. Long-running speech, ACP, Keychain, and
/// network work crosses explicit asynchronous adapter boundaries and publishes back here.
@MainActor
@Observable
final class AppModel {
    /// The current speech and execution state rendered by the menu and recording overlay.
    var state: ActivationState = .disabled

    /// Live input levels for `VoiceBars`, mirrored from the active speech
    /// session while `state == .capturing`. Reset by the session on stop, so
    /// this never holds a stale level once capture ends.
    /// The most recently submitted transcript shown as compact history.
    var lastTranscript = ""
    var captureLevels: [Double] = .init(repeating: 0, count: SpeechAudioLevelMeter.barCount)
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
    /// Whether saved ACP requests may include bounded focused Mac context.
    var capturesMacContext: Bool
    /// The editable spoken phrases that end a live agent conversation.
    var terminalPhrases: [String]
    /// The run a spoken terminal phrase asked to close, awaiting its
    /// `.completed` event. Ending a live turn can be asynchronous, so this
    /// outlives the moment the phrase was heard.
    @ObservationIgnored var pendingSpeechDismissalRunID: UUID?
    /// The last nonprompting Accessibility trust status observed by a lifecycle refresh.
    var macContextAccessStatus: MacContextAccessStatus = .notAuthorized
    /// The editable app-wide speech selection inherited by profiles.
    var defaultSpeechVoice: TextToSpeechVoiceSelection {
        didSet {
            if defaultSpeechVoice.backendID == .elevenLabs,
                let voiceID = defaultSpeechVoice.voiceID
            {
                retainedElevenLabsVoiceID = voiceID
            }
        }
    }
    private var retainedElevenLabsVoiceID: String
    /// Compatibility projection for the two originally shipped speech providers.
    var agentSpeechProvider: AgentSpeechProvider {
        get { defaultSpeechVoice.backendID == .elevenLabs ? .elevenLabs : .system }
        set {
            switch newValue {
            case .system:
                defaultSpeechVoice = TextToSpeechVoiceSelection(
                    backendID: .system,
                    voiceID: nil)
            case .elevenLabs:
                defaultSpeechVoice = TextToSpeechVoiceSelection(
                    backendID: .elevenLabs,
                    voiceID: retainedElevenLabsVoiceID)
            }
        }
    }
    /// The remembered ElevenLabs voice, including while another backend is selected.
    var elevenLabsVoiceID: String {
        get { retainedElevenLabsVoiceID }
        set {
            retainedElevenLabsVoiceID = newValue
            if defaultSpeechVoice.backendID == .elevenLabs {
                defaultSpeechVoice = TextToSpeechVoiceSelection(
                    backendID: .elevenLabs,
                    voiceID: newValue)
            }
        }
    }
    /// The in-memory ElevenLabs credential draft; persistence is Keychain-only.
    var elevenLabsAPIKey: String
    var activeTextToSpeechVoicePreviewContext: TextToSpeechVoicePreviewContext?
    var textToSpeechVoicePreviewFeedback:
        [TextToSpeechVoicePreviewContext: TextToSpeechVoicePreviewFeedback] = [:]
    var textToSpeechVoicesByBackend: [TextToSpeechBackendID: [TextToSpeechVoice]] = [:]
    var loadingTextToSpeechBackendIDs: Set<TextToSpeechBackendID> = []
    var textToSpeechVoiceErrors: [TextToSpeechBackendID: String] = [:]
    var settingsError: String?
    var isSavingSettings = false
    /// The latest immutable conversation snapshot shared by menu and panel presenters.
    var agentRunSnapshot: AgentRunSnapshot?
    /// Bounded identifier-only work proven interrupted during launch reconciliation.
    var interruptedAgentWork: [AgentInterruptedWorkMarker] = []

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
    @ObservationIgnored let continuityStore: any AgentContinuityStoring
    @ObservationIgnored let isExecutableFile: @MainActor (String) -> Bool
    @ObservationIgnored let isDirectory: @MainActor (String) -> Bool
    @ObservationIgnored let permissionRequest: @MainActor () async -> Bool
    @ObservationIgnored let macContextAccess: any MacContextAccessControlling
    @ObservationIgnored let macContextCapturer: ConfigurableMacContextCapturer
    @ObservationIgnored let shortcut: any PushToTalkShortcutManaging
    @ObservationIgnored let overlayPresenter: RecordingOverlayPresenter
    @ObservationIgnored var agentRunPresentation: AgentRunPresentation
    @ObservationIgnored let agentSessionPresentationRegistry: AgentSessionPresentationRegistry
    @ObservationIgnored let agentSessionEventScheduler: any AgentSessionEventScheduling
    @ObservationIgnored let agentRunPanelPresenter: AgentRunPanelPresenter
    @ObservationIgnored let soundPresenter: CaptureSoundPresenter
    @ObservationIgnored let agentConversationAudioPlayer: any AgentConversationAudioPlaying
    @ObservationIgnored let agentConversationAudioPresenter: AgentConversationAudioPresenter
    @ObservationIgnored let agentSpeechCredentialStore: any AgentSpeechCredentialStoring
    @ObservationIgnored let textToSpeechVoicePreview: any TextToSpeechVoicePreviewing
    @ObservationIgnored let textToSpeechBackendRegistry: TextToSpeechBackendRegistry
    @ObservationIgnored let agentSpeechSettingsState: AgentSpeechSettingsState
    @ObservationIgnored let diagnostics: any YapOpsDiagnosticRecording
    @ObservationIgnored var textToSpeechVoiceCatalogGenerations:
        [TextToSpeechBackendID: UInt64] = [:]
    @ObservationIgnored var textToSpeechVoicePreviewGeneration: UInt64 = 0
    @ObservationIgnored var agentLifecycleSequence: UInt64 = 0
    @ObservationIgnored var agentSessionAppRunGeneration: UInt64 = 0
    @ObservationIgnored var agentSessionHandlerGeneration: UInt64 = 0
    @ObservationIgnored var agentPresentationProfile: WakeProfile?
    @ObservationIgnored var settingsSaveGeneration: UInt64 = 0
    @ObservationIgnored var startupGeneration: UInt64 = 0
    var startupPhase: AppModelStartupPhase = .idle
    @ObservationIgnored var isShutdown = false
    @ObservationIgnored var isShutdownComplete = false
    @ObservationIgnored var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored var permissionGranted = false
    @ObservationIgnored var permissionTask: Task<Bool, Never>?
    @ObservationIgnored var permissionAuthorization: AppModelEffectAuthorization?
    @ObservationIgnored var credentialLoadTask: Task<String?, any Error>?
    @ObservationIgnored var credentialLoadGeneration: UInt64?
    @ObservationIgnored var heldHotKeyProfileID: UUID?
    @ObservationIgnored var recordingShortcut = false
    @ObservationIgnored var activeProfile: WakeProfile?
    @ObservationIgnored var pendingAgentHandoff: RecordingOverlayHandoff?
    @ObservationIgnored var pendingInterruptedAgentWork:
        [UUID: [AgentInterruptedWorkMarker]] = [:]
    @ObservationIgnored lazy var coordinator = YapOpsCoordinator(
        speechSession: speechSession,
        commandRunner: commandRunner,
        agentRunner: agentRunner,
        agentRunContinuity: { [weak self] profileID in
            self?.agentRunContinuityRequest(for: profileID) ?? AgentRunContinuityRequest()
        },
        contextCapturer: macContextCapturer,
        configuration: { [weak self] in
            guard let self else { throw ModelError.unavailable }
            return try self.savedConfiguration()
        },
        terminalPhrases: { [weak self] in
            self?.terminalPhrases ?? AppPreferences.defaultTerminalPhrases
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
        artifactOpener: any AgentArtifactOpening = SystemAgentArtifactOpener(),
        shortcut: any PushToTalkShortcutManaging = PushToTalkShortcut(),
        speechSession: any SpeechSessionProtocol = AppleSpeechSession(),
        commandRunner: any CommandRunning = CommandRunner(),
        agentRunner: any AgentHarnessRunning = ACPAgentRunner(),
        continuityStore: any AgentContinuityStoring = InMemoryAgentContinuityStore(),
        permissionRequest: @escaping @MainActor () async -> Bool = SpeechPermissions.request,
        soundPlayer: any CaptureSoundPlaying = SystemCaptureSoundPlayer(),
        agentConversationAudioPlayer: (any AgentConversationAudioPlaying)? = nil,
        agentSpeechCredentialStore: any AgentSpeechCredentialStoring =
            KeychainAgentSpeechCredentialStore(),
        elevenLabsVoiceCatalog: any ElevenLabsVoiceCatalogLoading =
            ElevenLabsVoiceCatalogClient(),
        textToSpeechVoicePreview: (any TextToSpeechVoicePreviewing)? = nil,
        textToSpeechBackendRegistry: TextToSpeechBackendRegistry? = nil,
        macContextAccess: any MacContextAccessControlling =
            UnavailableMacContextAccessController(),
        macContextCapturer: any MacContextCapturing = EmptyMacContextCapturer(),
        isExecutableFile: @escaping @MainActor (String) -> Bool = AppModel.executableFileExists,
        isDirectory: @escaping @MainActor (String) -> Bool = AppModel.directoryExists,
        agentSessionEventScheduler: any AgentSessionEventScheduling =
            MainRunLoopAgentSessionEventScheduler(),
        startsAutomatically: Bool = true,
        diagnostics: any YapOpsDiagnosticRecording = YapOpsDiagnostics.shared
    ) {
        let storedElevenLabsAPIKey = ""
        let defaultSpeechVoice = preferences.defaultSpeechVoice
        let retainedElevenLabsVoiceID = defaultSpeechVoice.backendID == .elevenLabs
            ? defaultSpeechVoice.voiceID ?? preferences.elevenLabsVoiceID
            : preferences.elevenLabsVoiceID
        let agentSpeechSettingsState = AgentSpeechSettingsState(
            defaultSelection: defaultSpeechVoice,
            elevenLabsAPIKey: storedElevenLabsAPIKey)
        let resolvedTextToSpeechBackendRegistry = textToSpeechBackendRegistry ?? .live(
            elevenLabsCatalog: elevenLabsVoiceCatalog)
        let resolvedAgentConversationAudioPlayer =
            agentConversationAudioPlayer
            ?? AgentConversationAudioOrchestrator(
                speechConfiguration: { profile, readsInheritedReplies in
                    agentSpeechSettingsState.configuration(
                        for: profile.speechPreference,
                        readsInheritedReplies: readsInheritedReplies)
                },
                backendRegistry: resolvedTextToSpeechBackendRegistry,
                diagnostics: diagnostics)
        let resolvedTextToSpeechVoicePreview = textToSpeechVoicePreview
            ?? TextToSpeechVoicePreviewPlayer(
                backendRegistry: resolvedTextToSpeechBackendRegistry,
                diagnostics: diagnostics)

        self.preferences = preferences
        self.shortcut = shortcut
        self.speechSession = speechSession
        self.commandRunner = commandRunner
        self.agentRunner = agentRunner
        self.continuityStore = continuityStore
        self.isExecutableFile = isExecutableFile
        self.isDirectory = isDirectory
        self.agentSessionEventScheduler = agentSessionEventScheduler
        self.permissionRequest = permissionRequest
        self.macContextAccess = macContextAccess
        self.macContextCapturer = ConfigurableMacContextCapturer(
            capturer: macContextCapturer,
            enabled: preferences.capturesMacContext)
        self.agentSpeechCredentialStore = agentSpeechCredentialStore
        self.textToSpeechVoicePreview = resolvedTextToSpeechVoicePreview
        self.textToSpeechBackendRegistry = resolvedTextToSpeechBackendRegistry
        self.agentSpeechSettingsState = agentSpeechSettingsState
        self.diagnostics = diagnostics
        overlayPresenter = RecordingOverlayPresenter(display: recordingOverlay)
        agentRunPresentation = AgentRunPresentation(diagnostics: diagnostics)
        agentSessionPresentationRegistry = AgentSessionPresentationRegistry()
        agentRunPanelPresenter = AgentRunPanelPresenter(
            display: agentRunPanel,
            artifactOpener: artifactOpener,
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
        capturesMacContext = preferences.capturesMacContext
        terminalPhrases = preferences.terminalPhrases
        self.defaultSpeechVoice = defaultSpeechVoice
        self.retainedElevenLabsVoiceID = retainedElevenLabsVoiceID
        elevenLabsAPIKey = storedElevenLabsAPIKey
        diagnostics.record(
            category: .app,
            event: "app_model.initialized",
            fields: [
                "profile_count": String(activeWakeProfiles.count),
                "enabled_profile_count": String(activeWakeProfiles.count(where: \.isEnabled)),
                "passive_enabled": String(passiveEnabled),
                "captures_mac_context": String(capturesMacContext),
                "speech_backend": defaultSpeechVoice.backendID.rawValue,
                "cloud_api_configured": String(!storedElevenLabsAPIKey.isEmpty),
                "starts_automatically": String(startsAutomatically),
            ])
        overlayPresenter.onCancel = { [weak self] in
            self?.cancelCapture()
        }
        bindAgentRunPresentation(agentRunPresentation)
        (speechSession as? SpeechAudioLevelReporting)?.onLevels = { [weak self] levels in
            self?.captureLevels = levels
        }
        agentRunPanelPresenter.onCancel = { [weak self] runID in
            self?.cancelAgentRun(runID: runID)
        }
        agentRunPanelPresenter.onResumeListening = { [weak self] runID in
            self?.resumeAgentConversationListening(runID: runID)
        }
        agentRunPanelPresenter.onEndConversation = { [weak self] runID in
            self?.endAgentConversation(runID: runID)
        }
        agentRunPanelPresenter.onSubmitFollowUp = { [weak self] runID, text in
            self?.submitAgentFollowUp(runID: runID, text: text)
        }
        agentRunPanelPresenter.onPermission = { [weak self] runID, key, optionID in
            self?.resolveAgentPermission(
                runID: runID,
                key: key,
                optionID: optionID)
        }
        agentRunPanelPresenter.onStopBackgroundTask = { [weak self] runID, taskID in
            self?.stopBackgroundTask(runID: runID, taskID: taskID)
        }
        agentRunPanelPresenter.onClose = { [weak self] runID in
            self?.agentRunPresentation.close(runID: runID)
        }
        agentRunPanelPresenter.onDelete = { [weak self] runID in
            guard let self, self.agentRunSnapshot?.runID == runID else { return }
            self.agentRunPresentation.discard(runID: runID)
            self.agentSessionPresentationRegistry.remove(runID: runID)
            self.agentRunSnapshot = nil
        }
        resolvedAgentConversationAudioPlayer.onSpeechOutputActiveChange = { [weak self] active in
            self?.diagnostics.record(
                category: .audio,
                event: "app_model.speech_output_received",
                fields: ["active": String(active)])
            self?.coordinator.setAgentSpeechOutputActive(active)
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
        guard isStartupReady else {
            diagnostics.record(
                category: .ui,
                event: "app_model.passive_toggle_deferred",
                fields: ["enabled": String(enabled)])
            return
        }
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
        case .paused: "paused"
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
        case .dismissedBySpeech(let runID):
            ["kind": "dismissed_by_speech", "run_id": runID.uuidString]
        case .started(let runID, _, let prompt):
            [
                "kind": "started", "run_id": runID.uuidString,
                "input_character_count": String(prompt.count),
            ]
        case .followUpSubmitted(let runID, _, let prompt, _):
            [
                "kind": "follow_up_submitted", "run_id": runID.uuidString,
                "input_character_count": String(prompt.count),
            ]
        case .followUpDispositionChanged(let runID, _, _):
            ["kind": "follow_up_disposition_changed", "run_id": runID.uuidString]
        case .inputContextCaptured(let runID, _, _):
            ["kind": "input_context_captured", "run_id": runID.uuidString]
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
        case .historyRestorationStarted(let runID, _, _):
            ["kind": "history_restoration_started", "run_id": runID.uuidString]
        case .historyEvent(let runID, _, let event):
            [
                "kind": "history_event", "run_id": runID.uuidString,
                "event_kind": AppModel.eventKind(event),
            ]
        case .historyRestorationCompleted(let runID, _, let activation):
            [
                "kind": "history_restoration_completed",
                "run_id": runID.uuidString,
                "activation": activation.appModelDiagnosticName,
            ]
        case .historyRestorationAborted(let runID, _):
            ["kind": "history_restoration_aborted", "run_id": runID.uuidString]
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

extension AgentSessionActivation {
    fileprivate var appModelDiagnosticName: String {
        switch self {
        case .new: "new"
        case .loaded: "loaded"
        case .resumed: "resumed"
        case .freshAfterUnavailableBookmark: "fresh_after_unavailable_bookmark"
        case .freshBecauseRestorationUnsupported: "fresh_restoration_unsupported"
        }
    }
}

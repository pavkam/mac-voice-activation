// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

public enum AgentRunLifecycleEvent: Equatable, Sendable {
    case started(runID: UUID, profile: WakeProfile, prompt: String)
    case followUpSubmitted(runID: UUID, prompt: String)
    case notice(runID: UUID, message: String)
    case turnStarted(runID: UUID)
    case turnCancellationStarted(runID: UUID)
    case event(runID: UUID, event: AgentRunEvent)
    case turnCompleted(runID: UUID, result: AgentRunResult)
    case turnFailed(runID: UUID, message: String)
    case completed(runID: UUID, result: AgentRunResult)
    case failed(runID: UUID, message: String)
}

@MainActor
public final class VoiceActivationCoordinator {
    static let maximumPendingAgentPrompts = 16

    public private(set) var state: ActivationState = .disabled {
        didSet {
            diagnostics.record(
                category: .app,
                event: "coordinator.state_changed",
                fields: [
                    "previous_state": oldValue.coordinatorDiagnosticName,
                    "state": state.coordinatorDiagnosticName,
                ])
            onStateChange?(state)
            if state != .capturing {
                currentTranscript = ""
            }
        }
    }
    public private(set) var lastTranscript = "" {
        didSet {
            diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.last_transcript_changed",
                fields: ["character_count": String(lastTranscript.count)])
            onTranscriptChange?(lastTranscript)
        }
    }
    public private(set) var currentTranscript = "" {
        didSet {
            diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.current_transcript_changed",
                level: .debug,
                fields: ["character_count": String(currentTranscript.count)])
            onCurrentTranscriptChange?(currentTranscript)
        }
    }
    public private(set) var activeProfile: WakeProfile? {
        didSet {
            diagnostics.record(
                category: .app,
                event: "coordinator.active_profile_changed",
                fields: [
                    "has_profile": String(activeProfile != nil),
                    "profile_id": activeProfile?.id.uuidString ?? "",
                ])
            onActiveProfileChange?(activeProfile)
        }
    }

    public var onStateChange: ((ActivationState) -> Void)?
    public var onTranscriptChange: ((String) -> Void)?
    public var onCurrentTranscriptChange: ((String) -> Void)?
    public var onActiveProfileChange: ((WakeProfile?) -> Void)?
    public var onAgentRunEvent: ((AgentRunLifecycleEvent) -> Void)?
    public var onAgentSpeechCancellation: (() -> Void)?
    public var onAgentVoiceUtterance: ((String) -> Bool)?

    private let speechSession: any SpeechSessionProtocol
    private let commandRunner: any CommandRunning
    private let agentRunner: any AgentHarnessRunning
    private let configuration: () throws -> ActivationConfiguration
    private let timing: ActivationTiming
    private let diagnostics: any VoiceActivationDiagnosticRecording
    private var passiveEnabled = false
    private var pushToTalkActive = false
    private var capturedAction: WakeProfileAction?
    private var capturedLocaleID: String?
    private var executingAction: WakeProfileAction?
    private var activeAgentRunID: UUID?
    private var capturedCommand = ""
    private var generation = 0
    private var captureGeneration = 0
    private var executionGeneration = 0
    private var wakeHandoffTask: Task<Void, Never>?
    private var initialSilenceTask: Task<Void, Never>?
    private var inactivityTask: Task<Void, Never>?
    private var hardStopTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var executionTask: Task<Void, Never>?
    private var agentCancellationTask: Task<Void, Never>?
    private var agentCancellationToken: UUID?
    private var pendingAgentPrompts: [String] = []
    private var conversationUtterance = ""
    private var conversationCaptureGeneration = 0
    private var conversationInactivityTask: Task<Void, Never>?
    private var conversationHardStopTask: Task<Void, Never>?
    private var conversationRestartTask: Task<Void, Never>?
    private var pushToTalkContinuesConversation = false
    private var agentConversationEndResult: AgentRunResult?
    private var agentSpeechOutputActive = false
    private var agentTurnHadActivity = false

    public convenience init(
        speechSession: any SpeechSessionProtocol,
        commandRunner: any CommandRunning,
        agentRunner: any AgentHarnessRunning = ACPAgentRunner(),
        configuration: @escaping () throws -> ActivationConfiguration,
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.init(
            speechSession: speechSession,
            commandRunner: commandRunner,
            agentRunner: agentRunner,
            configuration: configuration,
            timing: .standard,
            diagnostics: diagnostics)
    }

    init(
        speechSession: any SpeechSessionProtocol,
        commandRunner: any CommandRunning,
        agentRunner: any AgentHarnessRunning = ACPAgentRunner(),
        configuration: @escaping () throws -> ActivationConfiguration,
        timing: ActivationTiming,
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.speechSession = speechSession
        self.commandRunner = commandRunner
        self.agentRunner = agentRunner
        self.configuration = configuration
        self.timing = timing
        self.diagnostics = diagnostics
        diagnostics.record(category: .app, event: "coordinator.initialized")
    }

    public func setPassiveEnabled(_ enabled: Bool) {
        diagnostics.record(
            category: .app,
            event: "coordinator.passive_listening_requested",
            fields: [
                "enabled": String(enabled),
                "conversation_active": String(isAgentConversationActive),
            ])
        passiveEnabled = enabled
        guard !isAgentConversationActive else { return }

        if enabled {
            guard !pushToTalkActive else { return }
            startPassiveListening()
        } else {
            stopActiveSession()
            state = .disabled
        }
    }

    public func refreshConfiguration() {
        guard passiveEnabled, !pushToTalkActive, !isAgentConversationActive else {
            diagnostics.record(
                category: .settings,
                event: "coordinator.configuration_refresh_deferred",
                fields: [
                    "passive_enabled": String(passiveEnabled),
                    "push_to_talk_active": String(pushToTalkActive),
                    "conversation_active": String(isAgentConversationActive),
                ])
            return
        }
        diagnostics.record(category: .settings, event: "coordinator.configuration_refreshed")
        startPassiveListening()
    }

    public func pushToTalkPressed() {
        guard let profileID = try? configuration().profiles.first?.id else { return }
        pushToTalkPressed(profileID: profileID)
    }

    public func pushToTalkPressed(profileID: UUID) {
        diagnostics.record(
            category: .hotKey,
            event: "coordinator.push_to_talk_pressed",
            fields: ["profile_id": profileID.uuidString])
        guard !pushToTalkActive else {
            diagnostics.record(
                category: .hotKey,
                event: "coordinator.push_to_talk_ignored",
                fields: ["reason": "already_active"])
            return
        }

        do {
            let config = try configuration()
            guard let profile = config.profiles.first(where: { $0.id == profileID }) else {
                throw CoordinatorError.profileUnavailable
            }

            if isAgentConversationActive {
                pushToTalkActive = true
                pushToTalkContinuesConversation = true
                stopActiveSession()
                capturedCommand = ""
                currentTranscript = ""
                state = .capturing
                startSession(
                    mode: .pushToTalk,
                    localeID: capturedLocaleID ?? config.localeID)
                return
            }

            executionGeneration &+= 1
            restartTask?.cancel()
            restartTask = nil
            executionTask?.cancel()
            executionTask = nil
            executingAction = nil
            activeAgentRunID = nil
            pushToTalkActive = true
            stopActiveSession()
            capturedCommand = ""
            currentTranscript = ""
            activeProfile = profile
            capturedAction = profile.action
            capturedLocaleID = config.localeID
            state = .capturing
            startSession(mode: .pushToTalk, localeID: config.localeID)
        } catch {
            diagnostics.record(
                category: .hotKey,
                event: "coordinator.push_to_talk_failed",
                level: .error,
                fields: ["error_type": String(describing: type(of: error))])
            state = .failed(error.localizedDescription)
            pushToTalkActive = false
            resumePassiveIfNeeded()
        }
    }

    public func pushToTalkReleased() {
        guard pushToTalkActive else {
            diagnostics.record(
                category: .hotKey,
                event: "coordinator.push_to_talk_release_ignored",
                fields: ["reason": "not_active"])
            return
        }
        let transcript = capturedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        diagnostics.record(
            category: .hotKey,
            event: "coordinator.push_to_talk_released",
            fields: [
                "character_count": String(transcript.count),
                "continues_conversation": String(pushToTalkContinuesConversation),
            ])

        if pushToTalkContinuesConversation {
            pushToTalkActive = false
            pushToTalkContinuesConversation = false
            stopActiveSession()
            state = .executing
            startConversationListening()
            guard !transcript.isEmpty else { return }
            if CaptureCancellationMatcher.matches(transcript, isComplete: true) {
                cancelAgentConversationFromSpeech()
            } else {
                submitAgentFollowUp(transcript)
            }
            return
        }

        if CaptureCancellationMatcher.matches(transcript, isComplete: true) {
            cancelCapture()
            return
        }

        pushToTalkActive = false
        stopActiveSession()

        guard !transcript.isEmpty else {
            resumePassiveIfNeeded()
            return
        }
        execute(transcript)
    }

    public func cancelCapture() {
        guard state == .capturing else {
            diagnostics.record(
                category: .ui,
                event: "coordinator.capture_cancel_ignored",
                fields: ["state": state.coordinatorDiagnosticName])
            return
        }
        diagnostics.record(category: .ui, event: "coordinator.capture_cancelled")
        pushToTalkActive = false
        capturedCommand = ""
        stopActiveSession()
        if pushToTalkContinuesConversation {
            pushToTalkContinuesConversation = false
            state = .executing
            startConversationListening()
            return
        }
        resumePassiveIfNeeded()
    }

    public func cancelAgentRun() {
        guard
            case .agent = executingAction,
            let runID = activeAgentRunID,
            executionTask != nil,
            agentCancellationTask == nil
        else {
            diagnostics.record(
                category: .agent,
                event: "coordinator.agent_cancel_ignored",
                fields: ["reason": "no_cancellable_turn"])
            return
        }

        diagnostics.record(
            category: .agent,
            event: "coordinator.agent_cancel_requested",
            fields: ["run_id": runID.uuidString])

        onAgentRunEvent?(.turnCancellationStarted(runID: runID))
        executionGeneration &+= 1
        executionTask?.cancel()
        executionTask = nil
        beginAgentCancellation(runID: runID)
    }

    public func endAgentConversation() {
        diagnostics.record(category: .agent, event: "coordinator.conversation_end_requested")
        requestAgentConversationEnd(
            result: AgentRunResult(stopReason: .endTurn))
    }

    private func cancelAgentConversationFromSpeech() {
        requestAgentConversationEnd(
            result: AgentRunResult(stopReason: .cancelled))
    }

    private func requestAgentConversationEnd(result: AgentRunResult) {
        guard case .agent = executingAction, let runID = activeAgentRunID else { return }
        guard agentConversationEndResult == nil else { return }
        pendingAgentPrompts.removeAll()
        agentConversationEndResult = result
        stopActiveSession()
        guard agentCancellationTask == nil else { return }
        guard executionTask != nil else {
            finishAgentConversation(runID: runID, result: result)
            return
        }

        onAgentRunEvent?(.turnCancellationStarted(runID: runID))
        executionGeneration &+= 1
        executionTask?.cancel()
        executionTask = nil
        beginAgentCancellation(runID: runID)
    }

    public func setAgentSpeechOutputActive(_ active: Bool) {
        guard agentSpeechOutputActive != active else { return }
        agentSpeechOutputActive = active
        diagnostics.record(
            category: .audio,
            event: "coordinator.agent_speech_output_changed",
            fields: [
                "active": String(active),
                "conversation_active": String(isAgentConversationActive),
                "push_to_talk_active": String(pushToTalkActive),
            ])
        guard isAgentConversationActive, !pushToTalkActive else { return }
        if active {
            resetConversationCapture()
            conversationUtterance = ""
            currentTranscript = ""
        } else {
            startConversationListening()
        }
    }

    public func resolveAgentPermission(
        runID: UUID,
        turnToken: AgentTurnToken,
        requestID: ACPRequestID,
        optionID: String?
    ) {
        guard
            case .agent = executingAction,
            activeAgentRunID == runID
        else {
            diagnostics.record(
                category: .agent,
                event: "coordinator.permission_resolution_ignored",
                fields: ["run_id": runID.uuidString])
            return
        }

        diagnostics.record(
            category: .agent,
            event: "coordinator.permission_resolution_requested",
            fields: [
                "run_id": runID.uuidString,
                "has_option": String(optionID != nil),
            ])

        let activeExecutionGeneration = executionGeneration
        Task { @MainActor [weak self, agentRunner] in
            guard
                let self,
                self.executionGeneration == activeExecutionGeneration,
                self.activeAgentRunID == runID
            else { return }
            await agentRunner.resolvePermission(
                turnToken: turnToken,
                requestID: requestID,
                optionID: optionID)
        }
    }

    public func stop() {
        diagnostics.record(category: .app, event: "coordinator.stop_requested")
        executionGeneration &+= 1
        passiveEnabled = false
        pushToTalkActive = false
        restartTask?.cancel()
        restartTask = nil
        executionTask?.cancel()
        executionTask = nil
        agentCancellationTask?.cancel()
        agentCancellationTask = nil
        agentCancellationToken = nil
        pendingAgentPrompts.removeAll()
        pushToTalkContinuesConversation = false
        agentConversationEndResult = nil
        agentSpeechOutputActive = false
        resetConversationCapture()
        conversationRestartTask?.cancel()
        conversationRestartTask = nil
        executingAction = nil
        activeAgentRunID = nil
        capturedAction = nil
        capturedLocaleID = nil
        stopActiveSession()
        state = .disabled
        Task { [agentRunner] in
            await agentRunner.shutdown()
        }
    }

    private var isAgentConversationActive: Bool {
        if case .agent = executingAction {
            return true
        }
        return agentCancellationTask != nil
    }

    private func startPassiveListening() {
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.passive_listening_starting")
        stopActiveSession()
        capturedCommand = ""
        currentTranscript = ""
        activeProfile = nil
        capturedAction = nil
        capturedLocaleID = nil

        do {
            let config = try configuration()
            let enabledProfiles = config.profiles.filter(\.isEnabled)
            guard !enabledProfiles.isEmpty else {
                diagnostics.record(
                    category: .speechRecognition,
                    event: "coordinator.passive_listening_not_started",
                    level: .warning,
                    fields: ["reason": "no_enabled_profiles"])
                state = .disabled
                return
            }
            state = .listening
            startSession(
                mode: .passiveWake,
                localeID: config.localeID,
                contextualStrings: enabledProfiles.map(\.wakePhrase))
        } catch {
            diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.passive_listening_failed",
                level: .error,
                fields: ["error_type": String(describing: type(of: error))])
            state = .failed(error.localizedDescription)
        }
    }

    private func startSession(
        mode: SpeechSessionMode,
        localeID: String,
        contextualStrings: [String] = []
    ) {
        generation &+= 1
        let activeGeneration = generation
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.session_starting",
            fields: [
                "generation": String(activeGeneration),
                "mode": mode.coordinatorDiagnosticName,
                "contextual_phrase_count": String(contextualStrings.count),
            ])
        do {
            try speechSession.start(
                mode: mode,
                localeID: localeID,
                contextualStrings: contextualStrings,
                onUpdate: { [weak self] update in
                    guard let self, self.generation == activeGeneration else { return }
                    self.handle(update, mode: mode)
                },
                onInterruption: { [weak self] in
                    guard let self, self.generation == activeGeneration else { return }
                    self.handleInterruption(mode: mode)
                })
            diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.session_started",
                fields: [
                    "generation": String(activeGeneration),
                    "mode": mode.coordinatorDiagnosticName,
                ])
        } catch {
            diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.session_start_failed",
                level: .error,
                fields: [
                    "generation": String(activeGeneration),
                    "mode": mode.coordinatorDiagnosticName,
                    "error_type": String(describing: type(of: error)),
                ])
            state = .failed(error.localizedDescription)
            if mode == .conversation {
                scheduleConversationRestart()
            } else if mode == .passiveWake || mode == .commandCapture {
                schedulePassiveRestart()
            }
        }
    }

    private func handleInterruption(mode: SpeechSessionMode) {
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.session_interrupted",
            level: .warning,
            fields: ["mode": mode.coordinatorDiagnosticName])
        stopActiveSession()
        capturedCommand = ""
        currentTranscript = ""
        if mode == .pushToTalk {
            pushToTalkActive = false
        }

        if mode == .conversation, isAgentConversationActive {
            state = .executing
            scheduleConversationRestart()
            return
        }

        if passiveEnabled {
            state = .listening
            schedulePassiveRestart()
        } else {
            state = .disabled
        }
    }

    private func handle(_ update: SpeechUpdate, mode: SpeechSessionMode) {
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.recognition_update",
            level: update.errorDescription == nil ? .debug : .error,
            fields: [
                "mode": mode.coordinatorDiagnosticName,
                "character_count": String(update.transcript.count),
                "is_final": String(update.isFinal),
                "has_error": String(update.errorDescription != nil),
            ])
        if let error = update.errorDescription {
            stopActiveSession()
            state = .failed(error)
            if mode == .conversation {
                scheduleConversationRestart()
            } else if mode == .passiveWake || mode == .commandCapture {
                schedulePassiveRestart()
            }
            return
        }

        switch mode {
        case .pushToTalk:
            capturedCommand = update.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            currentTranscript = capturedCommand
            if CaptureCancellationMatcher.matches(
                capturedCommand,
                isComplete: update.isFinal)
            {
                if pushToTalkContinuesConversation {
                    pushToTalkActive = false
                    pushToTalkContinuesConversation = false
                    stopActiveSession()
                    state = .executing
                    startConversationListening()
                    cancelAgentConversationFromSpeech()
                } else {
                    cancelCapture()
                }
            }
        case .commandCapture:
            handleCommandCapture(update)
        case .conversation:
            handleConversationCapture(update)
        case .passiveWake:
            handlePassive(update)
        }
    }

    private func handlePassive(_ update: SpeechUpdate) {
        let profiles: [WakeProfile]
        let localeID: String
        if state == .capturing, let activeProfile, let capturedLocaleID {
            profiles = [activeProfile]
            localeID = capturedLocaleID
        } else {
            do {
                let config = try configuration()
                profiles = config.profiles
                localeID = config.localeID
            } catch {
                stopActiveSession()
                state = .failed(error.localizedDescription)
                return
            }
        }

        guard
            let match = WakePhraseMatcher.match(
                in: update.transcript,
                profiles: profiles)
        else {
            diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.wake_phrase_not_matched",
                level: .debug,
                fields: [
                    "is_final": String(update.isFinal),
                    "character_count": String(update.transcript.count),
                ])
            if wakeHandoffTask != nil {
                cancelWakeHandoff()
                activeProfile = nil
                capturedAction = nil
                capturedLocaleID = nil
                state = .listening
            }
            if update.isFinal { startPassiveListening() }
            return
        }

        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.wake_phrase_matched",
            fields: [
                "profile_id": match.profile.id.uuidString,
                "command_character_count": String(match.command.count),
                "is_final": String(update.isFinal),
            ])

        if capturedAction == nil {
            activeProfile = match.profile
            capturedAction = match.profile.action
            capturedLocaleID = localeID
        }
        capturedCommand = match.command
        currentTranscript = match.command
        state = .capturing

        if CaptureCancellationMatcher.matches(match.command, isComplete: update.isFinal) {
            cancelCapture()
            return
        }

        guard !match.command.isEmpty else {
            if update.isFinal {
                startCommandCapture(localeID: localeID)
            } else {
                scheduleWakeHandoff(localeID: localeID)
            }
            return
        }

        cancelWakeHandoff()
        cancelCaptureInitialSilence()
        scheduleCaptureInactivity()
        scheduleCaptureHardStop()

        if update.isFinal {
            finishPassiveCapture()
        }
    }

    private func startCommandCapture(localeID: String) {
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.command_capture_started")
        stopActiveSession()
        currentTranscript = ""
        state = .capturing
        startSession(mode: .commandCapture, localeID: localeID)
        scheduleCaptureInitialSilence()
        scheduleCaptureHardStop()
    }

    private func scheduleWakeHandoff(localeID: String) {
        guard wakeHandoffTask == nil else { return }
        let activeGeneration = generation
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.wake_handoff_scheduled",
            fields: ["generation": String(activeGeneration)])
        wakeHandoffTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.wakeHandoffDelay)
            guard
                !Task.isCancelled,
                let self,
                self.generation == activeGeneration,
                self.capturedCommand.isEmpty
            else { return }
            self.wakeHandoffTask = nil
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.wake_handoff_fired",
                fields: ["generation": String(activeGeneration)])
            self.startCommandCapture(localeID: localeID)
        }
    }

    private func cancelWakeHandoff() {
        let wasScheduled = wakeHandoffTask != nil
        wakeHandoffTask?.cancel()
        wakeHandoffTask = nil
        if wasScheduled {
            diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.wake_handoff_cancelled")
        }
    }

    private func restartCommandCapture(localeID: String) {
        stopSpeechSession()
        startSession(mode: .commandCapture, localeID: localeID)
    }

    private func handleCommandCapture(_ update: SpeechUpdate) {
        capturedCommand = update.transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        currentTranscript = capturedCommand

        if CaptureCancellationMatcher.matches(
            capturedCommand,
            isComplete: update.isFinal)
        {
            cancelCapture()
            return
        }

        guard !capturedCommand.isEmpty else {
            if update.isFinal {
                do {
                    restartCommandCapture(localeID: try configuration().localeID)
                } catch {
                    stopActiveSession()
                    state = .failed(error.localizedDescription)
                }
            }
            return
        }

        cancelCaptureInitialSilence()
        scheduleCaptureInactivity()
        if update.isFinal {
            finishPassiveCapture()
        }
    }

    private func startConversationListening() {
        guard
            isAgentConversationActive,
            !pushToTalkActive,
            let localeID = capturedLocaleID
        else {
            diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.conversation_listening_not_started",
                level: .debug,
                fields: [
                    "conversation_active": String(isAgentConversationActive),
                    "push_to_talk_active": String(pushToTalkActive),
                    "has_locale": String(capturedLocaleID != nil),
                ])
            return
        }

        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.conversation_listening_started")

        resetConversationCapture()
        stopSpeechSession()
        conversationUtterance = ""
        currentTranscript = ""
        state = .executing
        startSession(
            mode: .conversation,
            localeID: localeID,
            contextualStrings: [
                "stop", "cancel", "dismiss", "allow", "allow all", "deny", "deny all",
            ])
    }

    private func handleConversationCapture(_ update: SpeechUpdate) {
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.conversation_capture_update",
            level: .debug,
            fields: [
                "character_count": String(update.transcript.count),
                "is_final": String(update.isFinal),
                "speech_output_active": String(agentSpeechOutputActive),
            ])
        if agentSpeechOutputActive {
            let transcript = update.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if CaptureCancellationMatcher.matches(transcript, isComplete: update.isFinal) {
                agentSpeechOutputActive = false
                diagnostics.record(
                    category: .agent,
                    event: "coordinator.voice_cancel_during_speech")
                onAgentSpeechCancellation?()
                cancelAgentConversationFromSpeech()
                return
            }
            guard !transcript.isEmpty else {
                currentTranscript = ""
                if update.isFinal {
                    startConversationListening()
                }
                return
            }

            // Clear this before stopping playback. The synchronous speech callback
            // must not replace the recognition session that owns this utterance.
            agentSpeechOutputActive = false
            diagnostics.record(
                category: .audio,
                event: "coordinator.speech_barged_in",
                fields: ["character_count": String(transcript.count)])
            onAgentSpeechCancellation?()
        }

        conversationUtterance = update.transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        currentTranscript = conversationUtterance

        guard !conversationUtterance.isEmpty else {
            if update.isFinal {
                startConversationListening()
            }
            return
        }

        scheduleConversationInactivity()
        scheduleConversationHardStop()
        if update.isFinal {
            finishConversationUtterance()
        }
    }

    private func scheduleConversationInactivity() {
        let activeGeneration = conversationCaptureGeneration
        conversationInactivityTask?.cancel()
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.conversation_inactivity_scheduled",
            fields: ["generation": String(activeGeneration)])
        conversationInactivityTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.captureInactivity)
            guard
                !Task.isCancelled,
                let self,
                self.conversationCaptureGeneration == activeGeneration
            else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.conversation_inactivity_fired",
                fields: ["generation": String(activeGeneration)])
            self.finishConversationUtterance()
        }
    }

    private func scheduleConversationHardStop() {
        guard conversationHardStopTask == nil else { return }
        let activeGeneration = conversationCaptureGeneration
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.conversation_hard_stop_scheduled",
            fields: ["generation": String(activeGeneration)])
        conversationHardStopTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.captureMaximum)
            guard
                !Task.isCancelled,
                let self,
                self.conversationCaptureGeneration == activeGeneration
            else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.conversation_hard_stop_fired",
                fields: ["generation": String(activeGeneration)])
            self.finishConversationUtterance()
        }
    }

    private func finishConversationUtterance() {
        let transcript = conversationUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.conversation_utterance_finished",
            fields: ["character_count": String(transcript.count)])
        startConversationListening()
        guard !transcript.isEmpty else { return }

        if CaptureCancellationMatcher.matches(transcript, isComplete: true) {
            diagnostics.record(
                category: .agent,
                event: "coordinator.conversation_cancel_voice_command")
            cancelAgentConversationFromSpeech()
        } else if onAgentVoiceUtterance?(transcript) == true {
            diagnostics.record(
                category: .agent,
                event: "coordinator.conversation_voice_command_handled")
            return
        } else {
            submitAgentFollowUp(transcript)
        }
    }

    private func resetConversationCapture() {
        conversationCaptureGeneration &+= 1
        conversationInactivityTask?.cancel()
        conversationInactivityTask = nil
        conversationHardStopTask?.cancel()
        conversationHardStopTask = nil
    }

    private func scheduleConversationRestart() {
        conversationRestartTask?.cancel()
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.conversation_restart_scheduled")
        conversationRestartTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.passiveRestart)
            guard !Task.isCancelled, let self, self.isAgentConversationActive else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.conversation_restart_fired")
            self.startConversationListening()
        }
    }

    private func scheduleCaptureInitialSilence() {
        guard initialSilenceTask == nil else { return }
        let activeCaptureGeneration = captureGeneration
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.capture_initial_silence_scheduled",
            fields: ["generation": String(activeCaptureGeneration)])
        initialSilenceTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.captureInitialSilence)
            guard
                !Task.isCancelled,
                let self,
                self.captureGeneration == activeCaptureGeneration
            else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.capture_initial_silence_fired",
                fields: ["generation": String(activeCaptureGeneration)])
            self.finishPassiveCapture()
        }
    }

    private func cancelCaptureInitialSilence() {
        initialSilenceTask?.cancel()
        initialSilenceTask = nil
    }

    private func scheduleCaptureInactivity() {
        let activeCaptureGeneration = captureGeneration
        inactivityTask?.cancel()
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.capture_inactivity_scheduled",
            fields: ["generation": String(activeCaptureGeneration)])
        inactivityTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.captureInactivity)
            guard
                !Task.isCancelled,
                let self,
                self.captureGeneration == activeCaptureGeneration
            else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.capture_inactivity_fired",
                fields: ["generation": String(activeCaptureGeneration)])
            self.finishPassiveCapture()
        }
    }

    private func scheduleCaptureHardStop() {
        guard hardStopTask == nil else { return }
        let activeCaptureGeneration = captureGeneration
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.capture_hard_stop_scheduled",
            fields: ["generation": String(activeCaptureGeneration)])
        hardStopTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.captureMaximum)
            guard
                !Task.isCancelled,
                let self,
                self.captureGeneration == activeCaptureGeneration
            else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.capture_hard_stop_fired",
                fields: ["generation": String(activeCaptureGeneration)])
            self.finishPassiveCapture()
        }
    }

    private func finishPassiveCapture() {
        let transcript = capturedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.capture_finished",
            fields: ["character_count": String(transcript.count)])

        if CaptureCancellationMatcher.matches(transcript, isComplete: true) {
            cancelCapture()
            return
        }

        stopActiveSession()
        guard !transcript.isEmpty else {
            resumePassiveIfNeeded()
            return
        }
        execute(transcript)
    }

    private func execute(_ transcript: String) {
        guard let action = capturedAction, let profile = activeProfile else {
            diagnostics.record(
                category: .app,
                event: "coordinator.execution_rejected",
                level: .error,
                fields: ["reason": "action_unavailable"])
            state = .failed(CoordinatorError.actionUnavailable.localizedDescription)
            resumePassiveAfterCooldown()
            return
        }

        executionGeneration &+= 1
        let activeExecutionGeneration = executionGeneration
        let pendingAgentCancellation = agentCancellationTask
        executionTask?.cancel()
        state = .executing
        lastTranscript = transcript
        diagnostics.record(
            category: .app,
            event: "coordinator.execution_queued",
            fields: [
                "generation": String(activeExecutionGeneration),
                "profile_id": profile.id.uuidString,
                "action": action.coordinatorDiagnosticName,
                "character_count": String(transcript.count),
                "waits_for_cancellation": String(pendingAgentCancellation != nil),
            ])

        guard let pendingAgentCancellation else {
            startExecution(
                action: action,
                profile: profile,
                transcript: transcript,
                generation: activeExecutionGeneration)
            return
        }

        executionTask = Task { @MainActor [weak self] in
            await pendingAgentCancellation.value
            do {
                try Task.checkCancellation()
            } catch {
                return
            }
            guard
                let self,
                self.executionGeneration == activeExecutionGeneration
            else { return }
            self.startExecution(
                action: action,
                profile: profile,
                transcript: transcript,
                generation: activeExecutionGeneration)
        }
    }

    private func startExecution(
        action: WakeProfileAction,
        profile: WakeProfile,
        transcript: String,
        generation: Int
    ) {
        guard executionGeneration == generation else { return }
        executingAction = action
        diagnostics.record(
            category: .app,
            event: "coordinator.execution_started",
            fields: [
                "generation": String(generation),
                "profile_id": profile.id.uuidString,
                "action": action.coordinatorDiagnosticName,
            ])

        switch action {
        case .command(let template):
            activeAgentRunID = nil
            executionTask = Task { @MainActor [weak self, commandRunner] in
                do {
                    try Task.checkCancellation()
                    guard
                        let self,
                        self.executionGeneration == generation
                    else { return }
                    _ = try await commandRunner.run(template: template, transcript: transcript)
                    self.finishCommandExecution(generation: generation)
                } catch {
                    guard let self else { return }
                    self.failCommandExecution(error, generation: generation)
                }
            }
        case .agent(let agentConfiguration):
            let runID = UUID()
            diagnostics.record(
                category: .agent,
                event: "coordinator.agent_conversation_started",
                fields: [
                    "run_id": runID.uuidString,
                    "profile_id": profile.id.uuidString,
                    "generation": String(generation),
                    "input_character_count": String(transcript.count),
                ])
            activeAgentRunID = runID
            pendingAgentPrompts.removeAll()
            agentConversationEndResult = nil
            onAgentRunEvent?(
                .started(
                    runID: runID,
                    profile: profile,
                    prompt: transcript))
            startConversationListening()
            startAgentTurn(
                prompt: transcript,
                profile: profile,
                configuration: agentConfiguration,
                runID: runID,
                generation: generation)
        }
    }

    private func submitAgentFollowUp(_ prompt: String) {
        guard case .agent = executingAction, let runID = activeAgentRunID else {
            diagnostics.record(
                category: .agent,
                event: "coordinator.follow_up_ignored",
                fields: ["reason": "no_active_conversation"])
            return
        }
        guard pendingAgentPrompts.count < Self.maximumPendingAgentPrompts else {
            diagnostics.record(
                category: .agent,
                event: "coordinator.follow_up_rejected",
                level: .warning,
                fields: [
                    "run_id": runID.uuidString,
                    "reason": "queue_full",
                    "pending_count": String(pendingAgentPrompts.count),
                ])
            onAgentRunEvent?(
                .notice(
                    runID: runID,
                    message: "Follow-up queue is full. Wait for the agent before speaking again."))
            return
        }
        pendingAgentPrompts.append(prompt)
        diagnostics.record(
            category: .agent,
            event: "coordinator.follow_up_queued",
            fields: [
                "run_id": runID.uuidString,
                "character_count": String(prompt.count),
                "pending_count": String(pendingAgentPrompts.count),
                "turn_active": String(executionTask != nil),
            ])
        onAgentRunEvent?(.followUpSubmitted(runID: runID, prompt: prompt))

        guard agentCancellationTask == nil else { return }
        guard executionTask == nil else {
            onAgentRunEvent?(.turnCancellationStarted(runID: runID))
            executionGeneration &+= 1
            executionTask?.cancel()
            executionTask = nil
            beginAgentCancellation(runID: runID)
            return
        }
        startNextAgentPrompt()
    }

    private func startNextAgentPrompt() {
        guard
            agentCancellationTask == nil,
            executionTask == nil,
            !pendingAgentPrompts.isEmpty,
            case .agent(let configuration) = executingAction,
            let profile = activeProfile,
            let runID = activeAgentRunID
        else { return }

        let prompt = pendingAgentPrompts.removeFirst()
        executionGeneration &+= 1
        let generation = executionGeneration
        onAgentRunEvent?(.turnStarted(runID: runID))
        state = .executing
        diagnostics.record(
            category: .agent,
            event: "coordinator.follow_up_started",
            fields: [
                "run_id": runID.uuidString,
                "generation": String(generation),
                "character_count": String(prompt.count),
                "remaining_pending_count": String(pendingAgentPrompts.count),
            ])
        startAgentTurn(
            prompt: prompt,
            profile: profile,
            configuration: configuration,
            runID: runID,
            generation: generation)
    }

    private func startAgentTurn(
        prompt: String,
        profile: WakeProfile,
        configuration: AgentHarnessConfiguration,
        runID: UUID,
        generation: Int
    ) {
        agentTurnHadActivity = false
        diagnostics.record(
            category: .agent,
            event: "coordinator.agent_turn_started",
            fields: [
                "run_id": runID.uuidString,
                "generation": String(generation),
                "input_character_count": String(prompt.count),
            ])
        executionTask = Task { @MainActor [weak self, agentRunner] in
            do {
                try Task.checkCancellation()
                guard
                    let self,
                    self.executionGeneration == generation,
                    self.activeAgentRunID == runID
                else { return }
                let result = try await agentRunner.run(
                    profileID: profile.id,
                    configuration: configuration,
                    prompt: prompt,
                    onEvent: { [weak self] event in
                        await self?.publishAgentEvent(
                            event,
                            runID: runID,
                            generation: generation)
                    })
                self.finishAgentExecution(
                    result,
                    runID: runID,
                    generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.failAgentExecution(
                    error,
                    runID: runID,
                    generation: generation)
            }
        }
    }

    private func finishCommandExecution(generation: Int) {
        guard executionGeneration == generation else { return }
        diagnostics.record(
            category: .command,
            event: "coordinator.command_finished",
            fields: ["generation": String(generation)])
        executionTask = nil
        executingAction = nil
        resumePassiveAfterCooldown()
    }

    private func failCommandExecution(_ error: any Error, generation: Int) {
        guard executionGeneration == generation else { return }
        diagnostics.record(
            category: .command,
            event: "coordinator.command_failed",
            level: .error,
            fields: [
                "generation": String(generation),
                "error_type": String(describing: type(of: error)),
            ])
        executionTask = nil
        executingAction = nil
        state = .failed(error.localizedDescription)
        resumePassiveAfterCooldown()
    }

    private func publishAgentEvent(
        _ event: AgentRunEvent,
        runID: UUID,
        generation: Int
    ) {
        guard
            executionGeneration == generation,
            activeAgentRunID == runID
        else {
            diagnostics.record(
                category: .agent,
                event: "coordinator.agent_event_discarded",
                level: .debug,
                fields: [
                    "run_id": runID.uuidString,
                    "event_kind": event.coordinatorDiagnosticName,
                    "event_generation": String(generation),
                    "generation": String(executionGeneration),
                ])
            return
        }
        if event.isMeaningfulAgentActivity {
            agentTurnHadActivity = true
        }
        diagnostics.record(
            category: .agent,
            event: "coordinator.agent_event_published",
            fields: [
                "run_id": runID.uuidString,
                "event_kind": event.coordinatorDiagnosticName,
                "generation": String(generation),
                "meaningful_activity": String(event.isMeaningfulAgentActivity),
            ])
        onAgentRunEvent?(.event(runID: runID, event: event))
    }

    private func finishAgentExecution(
        _ result: AgentRunResult,
        runID: UUID,
        generation: Int
    ) {
        guard
            executionGeneration == generation,
            activeAgentRunID == runID
        else { return }
        agentTurnHadActivity = false
        diagnostics.record(
            category: .agent,
            event: "coordinator.agent_turn_finished",
            fields: [
                "run_id": runID.uuidString,
                "generation": String(generation),
                "stop_reason": result.stopReason.rawValue,
                "pending_follow_up_count": String(pendingAgentPrompts.count),
            ])
        onAgentRunEvent?(.turnCompleted(runID: runID, result: result))
        executionTask = nil
        if pendingAgentPrompts.isEmpty {
            state = .executing
        } else {
            startNextAgentPrompt()
        }
    }

    private func failAgentExecution(
        _ error: any Error,
        runID: UUID,
        generation: Int
    ) {
        guard
            executionGeneration == generation,
            activeAgentRunID == runID
        else { return }
        let message = error.localizedDescription
        diagnostics.record(
            category: .agent,
            event: "coordinator.agent_turn_failed",
            level: .error,
            fields: [
                "run_id": runID.uuidString,
                "generation": String(generation),
                "had_activity": String(agentTurnHadActivity),
                "error_type": String(describing: type(of: error)),
            ])
        if agentTurnHadActivity {
            agentTurnHadActivity = false
            onAgentRunEvent?(.turnFailed(runID: runID, message: message))
            executionTask = nil
            state = .executing
            return
        }
        agentTurnHadActivity = false
        agentSpeechOutputActive = false
        onAgentRunEvent?(.failed(runID: runID, message: message))
        executionTask = nil
        executingAction = nil
        activeAgentRunID = nil
        pendingAgentPrompts.removeAll()
        agentConversationEndResult = nil
        resetConversationCapture()
        conversationRestartTask?.cancel()
        conversationRestartTask = nil
        stopSpeechSession()
        state = .failed(message)
        resumePassiveAfterCooldown()
    }

    private func beginAgentCancellation(runID: UUID) {
        guard agentCancellationTask == nil else { return }

        let token = UUID()
        diagnostics.record(
            category: .agent,
            event: "coordinator.agent_cancellation_started",
            fields: [
                "run_id": runID.uuidString,
                "cancellation_id": token.uuidString,
            ])
        agentCancellationToken = token
        agentCancellationTask = Task { @MainActor [weak self, agentRunner] in
            await agentRunner.cancel()
            guard let self, self.agentCancellationToken == token else { return }
            self.diagnostics.record(
                category: .agent,
                event: "coordinator.agent_cancellation_finished",
                fields: [
                    "run_id": runID.uuidString,
                    "cancellation_id": token.uuidString,
                ])
            self.agentCancellationTask = nil
            self.agentCancellationToken = nil
            guard self.activeAgentRunID == runID else { return }
            if let result = self.agentConversationEndResult {
                self.finishAgentConversation(
                    runID: runID,
                    result: result)
            } else if !self.pendingAgentPrompts.isEmpty {
                self.startNextAgentPrompt()
            } else {
                self.onAgentRunEvent?(
                    .turnCompleted(
                        runID: runID,
                        result: AgentRunResult(stopReason: .cancelled)))
                self.state = .executing
            }
        }
    }

    private func finishAgentConversation(runID: UUID, result: AgentRunResult) {
        guard activeAgentRunID == runID else { return }
        diagnostics.record(
            category: .agent,
            event: "coordinator.agent_conversation_finished",
            fields: [
                "run_id": runID.uuidString,
                "stop_reason": result.stopReason.rawValue,
            ])
        agentSpeechOutputActive = false
        executionTask?.cancel()
        executionTask = nil
        executingAction = nil
        activeAgentRunID = nil
        pendingAgentPrompts.removeAll()
        agentConversationEndResult = nil
        resetConversationCapture()
        conversationRestartTask?.cancel()
        conversationRestartTask = nil
        stopSpeechSession()
        onAgentRunEvent?(.completed(runID: runID, result: result))
        resumePassiveAfterCooldown()
    }

    private func resumePassiveAfterCooldown() {
        let activeExecutionGeneration = executionGeneration
        restartTask?.cancel()
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.passive_resume_scheduled",
            fields: ["generation": String(activeExecutionGeneration)])
        restartTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.executionCooldown)
            guard
                !Task.isCancelled,
                let self,
                self.executionGeneration == activeExecutionGeneration
            else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.passive_resume_fired",
                fields: ["generation": String(activeExecutionGeneration)])
            self.resumePassiveIfNeeded()
        }
    }

    private func schedulePassiveRestart() {
        restartTask?.cancel()
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.passive_restart_scheduled")
        restartTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.passiveRestart)
            guard !Task.isCancelled, let self else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.passive_restart_fired")
            self.resumePassiveIfNeeded()
        }
    }

    private func resumePassiveIfNeeded() {
        if passiveEnabled, !pushToTalkActive {
            startPassiveListening()
        } else if !pushToTalkActive {
            state = .disabled
        }
    }

    private func stopActiveSession() {
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.active_session_stopping",
            fields: [
                "generation": String(generation),
                "capture_generation": String(captureGeneration),
            ])
        captureGeneration &+= 1
        resetConversationCapture()
        conversationRestartTask?.cancel()
        conversationRestartTask = nil
        cancelWakeHandoff()
        cancelCaptureInitialSilence()
        inactivityTask?.cancel()
        inactivityTask = nil
        hardStopTask?.cancel()
        hardStopTask = nil
        stopSpeechSession()
    }

    private func stopSpeechSession() {
        generation &+= 1
        speechSession.stop()
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.speech_session_stopped",
            fields: ["generation": String(generation)])
    }
}

extension ActivationState {
    fileprivate var coordinatorDiagnosticName: String {
        switch self {
        case .disabled: "disabled"
        case .listening: "listening"
        case .capturing: "capturing"
        case .executing: "executing"
        case .failed: "failed"
        }
    }
}

extension SpeechSessionMode {
    fileprivate var coordinatorDiagnosticName: String {
        switch self {
        case .passiveWake: "passive_wake"
        case .commandCapture: "command_capture"
        case .conversation: "conversation"
        case .pushToTalk: "push_to_talk"
        }
    }
}

extension WakeProfileAction {
    fileprivate var coordinatorDiagnosticName: String {
        switch self {
        case .command: "command"
        case .agent: "agent"
        }
    }
}

extension AgentRunEvent {
    fileprivate var coordinatorDiagnosticName: String {
        switch self {
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
}

extension AgentRunEvent {
    fileprivate var isMeaningfulAgentActivity: Bool {
        switch self {
        case .agentMessageDelta(_, let text), .thoughtDelta(_, let text):
            !text.isEmpty
        case .toolCall, .toolCallUpdate, .permissionRequested, .deliveryNotice:
            true
        case .plan(let entries):
            !entries.isEmpty
        case .connected, .metadata, .diagnostic, .unknown:
            false
        }
    }
}

private enum CoordinatorError: Error, LocalizedError {
    case profileUnavailable
    case actionUnavailable

    var errorDescription: String? {
        switch self {
        case .profileUnavailable:
            "The push-to-talk profile is no longer available."
        case .actionUnavailable:
            "The captured voice action is no longer available."
        }
    }
}

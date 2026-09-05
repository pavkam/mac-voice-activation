// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// A main-actor conversation lifecycle event consumed by the app presentation layer.
public enum AgentRunLifecycleEvent: Equatable, Sendable {
    /// A new conversation was created from a captured command.
    case started(runID: UUID, profile: WakeProfile, prompt: String)
    /// A spoken or push-to-talk follow-up entered the current conversation queue.
    case followUpSubmitted(runID: UUID, prompt: String)
    /// The coordinator produced a concise recoverable lifecycle notice.
    case notice(runID: UUID, message: String)
    /// A queued prompt began one harness turn.
    case turnStarted(runID: UUID)
    /// Cancellation began and may still be waiting on the harness.
    case turnCancellationStarted(runID: UUID)
    /// A streaming ACP event belongs to the identified conversation.
    case event(runID: UUID, event: AgentRunEvent)
    /// One turn completed while the conversation remains available for follow-up.
    case turnCompleted(runID: UUID, result: AgentRunResult)
    /// One turn failed while the conversation presentation remains available.
    case turnFailed(runID: UUID, message: String)
    /// The full conversation ended normally.
    case completed(runID: UUID, result: AgentRunResult)
    /// The full conversation ended because of an unrecoverable failure.
    case failed(runID: UUID, message: String)
}

/// Coordinates passive wake detection, command capture, and live agent conversations.
@MainActor
public final class VoiceActivationCoordinator {
    static let maximumPendingAgentPrompts = 16
    static let agentLaunchCancellationGrace = Duration.milliseconds(25)

    /// The current high-level listening or execution state.
    public internal(set) var state: ActivationState = .disabled {
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
    /// The most recently submitted command transcript.
    public internal(set) var lastTranscript = "" {
        didSet {
            diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.last_transcript_changed",
                fields: ["character_count": String(lastTranscript.count)])
            onTranscriptChange?(lastTranscript)
        }
    }
    /// The partial transcript currently shown during capture.
    public internal(set) var currentTranscript = "" {
        didSet {
            diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.current_transcript_changed",
                level: .debug,
                fields: ["character_count": String(currentTranscript.count)])
            onCurrentTranscriptChange?(currentTranscript)
        }
    }
    /// The profile responsible for the current capture or operation.
    public internal(set) var activeProfile: WakeProfile? {
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

    /// Called synchronously on the main actor when ``state`` changes.
    public var onStateChange: ((ActivationState) -> Void)?
    /// Called synchronously when ``lastTranscript`` changes.
    public var onTranscriptChange: ((String) -> Void)?
    /// Called synchronously as the current partial transcript changes.
    public var onCurrentTranscriptChange: ((String) -> Void)?
    /// Called synchronously when the active wake profile changes.
    public var onActiveProfileChange: ((WakeProfile?) -> Void)?
    /// Delivers ordered agent conversation lifecycle events.
    public var onAgentRunEvent: ((AgentRunLifecycleEvent) -> Void)?
    /// Requests immediate cancellation of queued or playing agent speech.
    public var onAgentSpeechCancellation: (() -> Void)?
    /// Offers spoken conversation commands to the presentation layer before submission.
    public var onAgentVoiceUtterance: ((String) -> Bool)?

    let speechSession: any SpeechSessionProtocol
    let commandRunner: any CommandRunning
    let agentRunner: any AgentHarnessRunning
    let configuration: () throws -> ActivationConfiguration
    let timing: ActivationTiming
    let diagnostics: any VoiceActivationDiagnosticRecording
    var passiveEnabled = false
    var pushToTalkActive = false
    var capturedAction: WakeProfileAction?
    var capturedLocaleID: String?
    var executingAction: WakeProfileAction?
    var activeAgentRunID: UUID?
    var capturedCommand = ""
    var generation = 0
    var captureGeneration = 0
    var executionGeneration = 0
    var wakeHandoffTask: Task<Void, Never>?
    var initialSilenceTask: Task<Void, Never>?
    var inactivityTask: Task<Void, Never>?
    var hardStopTask: Task<Void, Never>?
    var restartTask: Task<Void, Never>?
    var executionTask: Task<Void, Never>?
    var agentCancellationTask: Task<Void, Never>?
    var agentCancellationToken: UUID?
    var pendingAgentPrompts: [String] = []
    var conversationUtterance = ""
    var conversationCaptureGeneration = 0
    var conversationInactivityTask: Task<Void, Never>?
    var conversationHardStopTask: Task<Void, Never>?
    var conversationRestartTask: Task<Void, Never>?
    var pushToTalkContinuesConversation = false
    var agentConversationEndResult: AgentRunResult?
    var agentSpeechOutputActive = false
    var agentTurnHadActivity = false

    /// Creates a coordinator with production timing and replaceable execution boundaries.
    ///
    /// - Parameters:
    ///   - speechSession: Owns the current microphone recognition session.
    ///   - commandRunner: Executes direct-command profiles.
    ///   - agentRunner: Runs and caches ACP agent sessions.
    ///   - configuration: Supplies a fresh immutable settings snapshot when needed.
    ///   - diagnostics: Records privacy-safe lifecycle metadata.
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

    /// Starts or stops passive wake-phrase recognition.
    ///
    /// - Parameter enabled: Whether passive recognition should run when no foreground task owns audio.
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

    /// Restarts idle passive recognition with the latest profile and locale snapshot.
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

    /// Begins push-to-talk capture for the first configured profile.
    public func pushToTalkPressed() {
        guard let profileID = try? configuration().profiles.first?.id else { return }
        pushToTalkPressed(profileID: profileID)
    }

    /// Begins push-to-talk capture for one profile or the current conversation.
    ///
    /// - Parameter profileID: The profile whose action receives the transcript.
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

    /// Ends push-to-talk capture and submits nonempty recognized text.
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

    /// Cancels foreground capture without invoking its configured action.
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

    /// Cancels the active agent turn while retaining the conversation presentation.
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

    /// Ends the complete live agent conversation and releases its cached session.
    public func endAgentConversation() {
        diagnostics.record(category: .agent, event: "coordinator.conversation_end_requested")
        requestAgentConversationEnd(
            result: AgentRunResult(stopReason: .endTurn))
    }

    func cancelAgentConversationFromSpeech() {
        requestAgentConversationEnd(
            result: AgentRunResult(stopReason: .cancelled))
    }

    func requestAgentConversationEnd(result: AgentRunResult) {
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

    /// Pauses microphone capture while synthesized speech owns audible output.
    ///
    /// - Parameter active: Whether agent speech is queued or currently playing.
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

    /// Answers a pending ACP permission request for the identified conversation.
    ///
    /// - Parameters:
    ///   - runID: The active conversation identity.
    ///   - turnToken: The active turn identity.
    ///   - requestID: The JSON-RPC request identifier.
    ///   - optionID: The selected permission option, or `nil` to cancel it.
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

        Task.detached(priority: .userInitiated) { [agentRunner] in
            await agentRunner.resolvePermission(
                turnToken: turnToken,
                requestID: requestID,
                optionID: optionID)
        }
    }

    /// Stops all recognition and execution, then shuts down the agent runner.
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

    var isAgentConversationActive: Bool {
        if case .agent = executingAction {
            return true
        }
        return agentCancellationTask != nil
    }

}

extension ActivationState {
    var coordinatorDiagnosticName: String {
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
    var coordinatorDiagnosticName: String {
        switch self {
        case .passiveWake: "passive_wake"
        case .commandCapture: "command_capture"
        case .conversation: "conversation"
        case .pushToTalk: "push_to_talk"
        }
    }
}

extension WakeProfileAction {
    var coordinatorDiagnosticName: String {
        switch self {
        case .command: "command"
        case .agent: "agent"
        }
    }
}

extension AgentRunEvent {
    var coordinatorDiagnosticName: String {
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
    var isMeaningfulAgentActivity: Bool {
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

enum CoordinatorError: Error, LocalizedError {
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

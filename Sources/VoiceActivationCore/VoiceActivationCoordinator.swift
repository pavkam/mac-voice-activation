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
    case completed(runID: UUID, result: AgentRunResult)
    case failed(runID: UUID, message: String)
}

@MainActor
public final class VoiceActivationCoordinator {
    static let maximumPendingAgentPrompts = 16

    public private(set) var state: ActivationState = .disabled {
        didSet {
            onStateChange?(state)
            if state != .capturing {
                currentTranscript = ""
            }
        }
    }
    public private(set) var lastTranscript = "" {
        didSet { onTranscriptChange?(lastTranscript) }
    }
    public private(set) var currentTranscript = "" {
        didSet { onCurrentTranscriptChange?(currentTranscript) }
    }
    public private(set) var activeProfile: WakeProfile? {
        didSet { onActiveProfileChange?(activeProfile) }
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

    public convenience init(
        speechSession: any SpeechSessionProtocol,
        commandRunner: any CommandRunning,
        agentRunner: any AgentHarnessRunning = ACPAgentRunner(),
        configuration: @escaping () throws -> ActivationConfiguration)
    {
        self.init(
            speechSession: speechSession,
            commandRunner: commandRunner,
            agentRunner: agentRunner,
            configuration: configuration,
            timing: .standard)
    }

    init(
        speechSession: any SpeechSessionProtocol,
        commandRunner: any CommandRunning,
        agentRunner: any AgentHarnessRunning = ACPAgentRunner(),
        configuration: @escaping () throws -> ActivationConfiguration,
        timing: ActivationTiming)
    {
        self.speechSession = speechSession
        self.commandRunner = commandRunner
        self.agentRunner = agentRunner
        self.configuration = configuration
        self.timing = timing
    }

    public func setPassiveEnabled(_ enabled: Bool) {
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
        guard passiveEnabled, !pushToTalkActive, !isAgentConversationActive else { return }
        startPassiveListening()
    }

    public func pushToTalkPressed() {
        guard let profileID = try? configuration().profiles.first?.id else { return }
        pushToTalkPressed(profileID: profileID)
    }

    public func pushToTalkPressed(profileID: UUID) {
        guard !pushToTalkActive else { return }

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
            state = .failed(error.localizedDescription)
            pushToTalkActive = false
            resumePassiveIfNeeded()
        }
    }

    public func pushToTalkReleased() {
        guard pushToTalkActive else { return }
        let transcript = capturedCommand.trimmingCharacters(in: .whitespacesAndNewlines)

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
        guard state == .capturing else { return }
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
        else { return }

        onAgentRunEvent?(.turnCancellationStarted(runID: runID))
        executionGeneration &+= 1
        executionTask?.cancel()
        executionTask = nil
        beginAgentCancellation(runID: runID)
    }

    public func endAgentConversation() {
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
        guard isAgentConversationActive, !pushToTalkActive else { return }
        startConversationListening()
    }

    public func resolveAgentPermission(
        runID: UUID,
        turnToken: AgentTurnToken,
        requestID: ACPRequestID,
        optionID: String?)
    {
        guard
            case .agent = executingAction,
            activeAgentRunID == runID
        else { return }

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
                state = .disabled
                return
            }
            state = .listening
            startSession(
                mode: .passiveWake,
                localeID: config.localeID,
                contextualStrings: enabledProfiles.map(\.wakePhrase))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func startSession(
        mode: SpeechSessionMode,
        localeID: String,
        contextualStrings: [String] = [])
    {
        generation &+= 1
        let activeGeneration = generation
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
        } catch {
            state = .failed(error.localizedDescription)
            if mode == .conversation {
                scheduleConversationRestart()
            } else if mode == .passiveWake || mode == .commandCapture {
                schedulePassiveRestart()
            }
        }
    }

    private func handleInterruption(mode: SpeechSessionMode) {
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

        guard let match = WakePhraseMatcher.match(
            in: update.transcript,
            profiles: profiles)
        else {
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
        wakeHandoffTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.wakeHandoffDelay)
            guard
                !Task.isCancelled,
                let self,
                self.generation == activeGeneration,
                self.capturedCommand.isEmpty
            else { return }
            self.wakeHandoffTask = nil
            self.startCommandCapture(localeID: localeID)
        }
    }

    private func cancelWakeHandoff() {
        wakeHandoffTask?.cancel()
        wakeHandoffTask = nil
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
        else { return }

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
        if agentSpeechOutputActive {
            let transcript = update.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if CaptureCancellationMatcher.matches(transcript, isComplete: update.isFinal) {
                agentSpeechOutputActive = false
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
        conversationInactivityTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.captureInactivity)
            guard
                !Task.isCancelled,
                let self,
                self.conversationCaptureGeneration == activeGeneration
            else { return }
            self.finishConversationUtterance()
        }
    }

    private func scheduleConversationHardStop() {
        guard conversationHardStopTask == nil else { return }
        let activeGeneration = conversationCaptureGeneration
        conversationHardStopTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.captureMaximum)
            guard
                !Task.isCancelled,
                let self,
                self.conversationCaptureGeneration == activeGeneration
            else { return }
            self.finishConversationUtterance()
        }
    }

    private func finishConversationUtterance() {
        let transcript = conversationUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
        startConversationListening()
        guard !transcript.isEmpty else { return }

        if CaptureCancellationMatcher.matches(transcript, isComplete: true) {
            cancelAgentConversationFromSpeech()
        } else if onAgentVoiceUtterance?(transcript) == true {
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
        conversationRestartTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.passiveRestart)
            guard !Task.isCancelled, let self, self.isAgentConversationActive else { return }
            self.startConversationListening()
        }
    }

    private func scheduleCaptureInitialSilence() {
        guard initialSilenceTask == nil else { return }
        let activeCaptureGeneration = captureGeneration
        initialSilenceTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.captureInitialSilence)
            guard
                !Task.isCancelled,
                let self,
                self.captureGeneration == activeCaptureGeneration
            else { return }
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
        inactivityTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.captureInactivity)
            guard
                !Task.isCancelled,
                let self,
                self.captureGeneration == activeCaptureGeneration
            else { return }
            self.finishPassiveCapture()
        }
    }

    private func scheduleCaptureHardStop() {
        guard hardStopTask == nil else { return }
        let activeCaptureGeneration = captureGeneration
        hardStopTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.captureMaximum)
            guard
                !Task.isCancelled,
                let self,
                self.captureGeneration == activeCaptureGeneration
            else { return }
            self.finishPassiveCapture()
        }
    }

    private func finishPassiveCapture() {
        let transcript = capturedCommand.trimmingCharacters(in: .whitespacesAndNewlines)

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
        generation: Int)
    {
        guard executionGeneration == generation else { return }
        executingAction = action

        switch action {
        case let .command(template):
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
        case let .agent(agentConfiguration):
            let runID = UUID()
            activeAgentRunID = runID
            pendingAgentPrompts.removeAll()
            agentConversationEndResult = nil
            onAgentRunEvent?(.started(
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
        guard case .agent = executingAction, let runID = activeAgentRunID else { return }
        guard pendingAgentPrompts.count < Self.maximumPendingAgentPrompts else {
            onAgentRunEvent?(.notice(
                runID: runID,
                message: "Follow-up queue is full. Wait for the agent before speaking again."))
            return
        }
        pendingAgentPrompts.append(prompt)
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
            case let .agent(configuration) = executingAction,
            let profile = activeProfile,
            let runID = activeAgentRunID
        else { return }

        let prompt = pendingAgentPrompts.removeFirst()
        executionGeneration &+= 1
        let generation = executionGeneration
        onAgentRunEvent?(.turnStarted(runID: runID))
        state = .executing
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
        generation: Int)
    {
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
        executionTask = nil
        executingAction = nil
        resumePassiveAfterCooldown()
    }

    private func failCommandExecution(_ error: any Error, generation: Int) {
        guard executionGeneration == generation else { return }
        executionTask = nil
        executingAction = nil
        state = .failed(error.localizedDescription)
        resumePassiveAfterCooldown()
    }

    private func publishAgentEvent(
        _ event: AgentRunEvent,
        runID: UUID,
        generation: Int)
    {
        guard
            executionGeneration == generation,
            activeAgentRunID == runID
        else { return }
        onAgentRunEvent?(.event(runID: runID, event: event))
    }

    private func finishAgentExecution(
        _ result: AgentRunResult,
        runID: UUID,
        generation: Int)
    {
        guard
            executionGeneration == generation,
            activeAgentRunID == runID
        else { return }
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
        generation: Int)
    {
        guard
            executionGeneration == generation,
            activeAgentRunID == runID
        else { return }
        let message = error.localizedDescription
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
        agentCancellationToken = token
        agentCancellationTask = Task { @MainActor [weak self, agentRunner] in
            await agentRunner.cancel()
            guard let self, self.agentCancellationToken == token else { return }
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
                self.onAgentRunEvent?(.turnCompleted(
                    runID: runID,
                    result: AgentRunResult(stopReason: .cancelled)))
                self.state = .executing
            }
        }
    }

    private func finishAgentConversation(runID: UUID, result: AgentRunResult) {
        guard activeAgentRunID == runID else { return }
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
        restartTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.executionCooldown)
            guard
                !Task.isCancelled,
                let self,
                self.executionGeneration == activeExecutionGeneration
            else { return }
            self.resumePassiveIfNeeded()
        }
    }

    private func schedulePassiveRestart() {
        restartTask?.cancel()
        restartTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.passiveRestart)
            guard !Task.isCancelled, let self else { return }
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

import Foundation

public enum AgentRunLifecycleEvent: Equatable, Sendable {
    case started(runID: UUID, profile: WakeProfile, prompt: String)
    case event(runID: UUID, event: AgentRunEvent)
    case completed(runID: UUID, result: AgentRunResult)
    case failed(runID: UUID, message: String)
}

@MainActor
public final class VoiceActivationCoordinator {
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
    private var agentCancellationShouldRestart = false

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
        guard !isAgentExecutionActive else { return }

        if enabled {
            guard !pushToTalkActive else { return }
            startPassiveListening()
        } else {
            stopActiveSession()
            state = .disabled
        }
    }

    public func refreshConfiguration() {
        guard passiveEnabled, !pushToTalkActive, !isAgentExecutionActive else { return }
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

            executionGeneration &+= 1
            restartTask?.cancel()
            restartTask = nil
            executionTask?.cancel()
            executionTask = nil
            if case .agent = executingAction, let runID = activeAgentRunID {
                beginAgentCancellation(
                    runID: runID,
                    scheduleRestart: false)
            } else {
                executingAction = nil
                activeAgentRunID = nil
            }
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

        if CaptureCancellationMatcher.matches(transcript, isComplete: true) {
            cancelCapture()
            return
        }

        pushToTalkActive = false
        stopActiveSession()

        guard !transcript.isEmpty else {
            resumePassiveAfterPendingAgentCancellation()
            return
        }
        execute(transcript)
    }

    public func cancelCapture() {
        guard state == .capturing else { return }
        pushToTalkActive = false
        capturedCommand = ""
        stopActiveSession()
        resumePassiveAfterPendingAgentCancellation()
    }

    public func cancelAgentRun() {
        guard
            state == .executing,
            case .agent = executingAction,
            let runID = activeAgentRunID,
            agentCancellationTask == nil
        else { return }

        executionGeneration &+= 1
        executionTask?.cancel()
        executionTask = nil
        beginAgentCancellation(
            runID: runID,
            scheduleRestart: true)
    }

    public func resolveAgentPermission(
        runID: UUID,
        turnToken: AgentTurnToken,
        requestID: ACPRequestID,
        optionID: String?)
    {
        guard
            state == .executing,
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
        agentCancellationShouldRestart = false
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

    private var isAgentExecutionActive: Bool {
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
            if mode == .passiveWake || mode == .commandCapture {
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
            if mode == .passiveWake || mode == .commandCapture {
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
                cancelCapture()
            }
        case .commandCapture:
            handleCommandCapture(update)
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
            onAgentRunEvent?(.started(
                runID: runID,
                profile: profile,
                prompt: transcript))
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
                        configuration: agentConfiguration,
                        prompt: transcript,
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
                } catch {
                    guard let self else { return }
                    self.failAgentExecution(
                        error,
                        runID: runID,
                        generation: generation)
                }
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
        onAgentRunEvent?(.completed(runID: runID, result: result))
        executionTask = nil
        executingAction = nil
        activeAgentRunID = nil
        resumePassiveAfterCooldown()
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
        onAgentRunEvent?(.failed(runID: runID, message: message))
        executionTask = nil
        executingAction = nil
        activeAgentRunID = nil
        state = .failed(message)
        resumePassiveAfterCooldown()
    }

    private func beginAgentCancellation(
        runID: UUID,
        scheduleRestart: Bool)
    {
        if agentCancellationTask != nil {
            agentCancellationShouldRestart = scheduleRestart
            return
        }

        let token = UUID()
        agentCancellationToken = token
        agentCancellationShouldRestart = scheduleRestart
        agentCancellationTask = Task { @MainActor [weak self, agentRunner] in
            await agentRunner.cancel()
            guard let self, self.agentCancellationToken == token else { return }
            let shouldRestart = self.agentCancellationShouldRestart
            self.agentCancellationTask = nil
            self.agentCancellationToken = nil
            self.agentCancellationShouldRestart = false
            if self.activeAgentRunID == runID {
                self.onAgentRunEvent?(.completed(
                    runID: runID,
                    result: AgentRunResult(stopReason: .cancelled)))
                self.executingAction = nil
                self.activeAgentRunID = nil
            }
            if shouldRestart {
                self.resumePassiveAfterCooldown()
            }
        }
    }

    private func resumePassiveAfterPendingAgentCancellation() {
        guard agentCancellationTask != nil else {
            resumePassiveIfNeeded()
            return
        }

        agentCancellationShouldRestart = true
        state = .executing
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

import Foundation

@MainActor
public final class VoiceActivationCoordinator {
    public private(set) var state: ActivationState = .disabled {
        didSet { onStateChange?(state) }
    }
    public private(set) var lastTranscript = "" {
        didSet { onTranscriptChange?(lastTranscript) }
    }

    public var onStateChange: ((ActivationState) -> Void)?
    public var onTranscriptChange: ((String) -> Void)?

    private let speechSession: any SpeechSessionProtocol
    private let commandRunner: any CommandRunning
    private let configuration: () throws -> ActivationConfiguration
    private let timing: ActivationTiming
    private var passiveEnabled = false
    private var pushToTalkActive = false
    private var capturedCommand = ""
    private var generation = 0
    private var inactivityTask: Task<Void, Never>?
    private var hardStopTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?

    public convenience init(
        speechSession: any SpeechSessionProtocol,
        commandRunner: any CommandRunning,
        configuration: @escaping () throws -> ActivationConfiguration)
    {
        self.init(
            speechSession: speechSession,
            commandRunner: commandRunner,
            configuration: configuration,
            timing: .standard)
    }

    init(
        speechSession: any SpeechSessionProtocol,
        commandRunner: any CommandRunning,
        configuration: @escaping () throws -> ActivationConfiguration,
        timing: ActivationTiming)
    {
        self.speechSession = speechSession
        self.commandRunner = commandRunner
        self.configuration = configuration
        self.timing = timing
    }

    public func setPassiveEnabled(_ enabled: Bool) {
        passiveEnabled = enabled
        if enabled {
            guard !pushToTalkActive else { return }
            startPassiveListening()
        } else {
            stopActiveSession()
            state = .disabled
        }
    }

    public func refreshConfiguration() {
        guard passiveEnabled, !pushToTalkActive else { return }
        startPassiveListening()
    }

    public func pushToTalkPressed() {
        guard !pushToTalkActive else { return }
        pushToTalkActive = true
        stopActiveSession()
        capturedCommand = ""
        state = .capturing

        do {
            let config = try configuration()
            startSession(mode: .pushToTalk, localeID: config.localeID)
        } catch {
            state = .failed(error.localizedDescription)
            pushToTalkActive = false
            resumePassiveIfNeeded()
        }
    }

    public func pushToTalkReleased() {
        guard pushToTalkActive else { return }
        pushToTalkActive = false
        let transcript = capturedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        stopActiveSession()

        guard !transcript.isEmpty else {
            resumePassiveIfNeeded()
            return
        }
        execute(transcript)
    }

    public func stop() {
        passiveEnabled = false
        pushToTalkActive = false
        stopActiveSession()
        state = .disabled
    }

    private func startPassiveListening() {
        stopActiveSession()
        capturedCommand = ""

        do {
            let config = try configuration()
            state = .listening
            startSession(mode: .passiveWake, localeID: config.localeID)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func startSession(mode: SpeechSessionMode, localeID: String) {
        generation &+= 1
        let activeGeneration = generation
        do {
            try speechSession.start(mode: mode, localeID: localeID) { [weak self] update in
                guard let self, self.generation == activeGeneration else { return }
                self.handle(update, mode: mode)
            }
        } catch {
            state = .failed(error.localizedDescription)
            if mode == .passiveWake || mode == .commandCapture {
                schedulePassiveRestart()
            }
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
        case .commandCapture:
            handleCommandCapture(update)
        case .passiveWake:
            handlePassive(update)
        }
    }

    private func handlePassive(_ update: SpeechUpdate) {
        let config: ActivationConfiguration
        do {
            config = try configuration()
        } catch {
            stopActiveSession()
            state = .failed(error.localizedDescription)
            return
        }

        guard let command = WakePhraseMatcher.command(
            in: update.transcript,
            wakePhrase: config.wakePhrase)
        else {
            if update.isFinal { startPassiveListening() }
            return
        }

        capturedCommand = command
        state = .capturing

        guard !command.isEmpty else {
            if update.isFinal {
                startCommandCapture(localeID: config.localeID)
            } else {
                scheduleCaptureHardStop()
            }
            return
        }

        scheduleCaptureInactivity()
        scheduleCaptureHardStop()

        if update.isFinal {
            finishPassiveCapture()
        }
    }

    private func startCommandCapture(localeID: String) {
        stopActiveSession()
        state = .capturing
        startSession(mode: .commandCapture, localeID: localeID)
        scheduleCaptureHardStop()
    }

    private func handleCommandCapture(_ update: SpeechUpdate) {
        capturedCommand = update.transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !capturedCommand.isEmpty else {
            if update.isFinal {
                do {
                    startCommandCapture(localeID: try configuration().localeID)
                } catch {
                    stopActiveSession()
                    state = .failed(error.localizedDescription)
                }
            }
            return
        }

        scheduleCaptureInactivity()
        if update.isFinal {
            finishPassiveCapture()
        }
    }

    private func scheduleCaptureInactivity() {
        let activeGeneration = generation
        inactivityTask?.cancel()
        inactivityTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.captureInactivity)
            guard !Task.isCancelled, let self, self.generation == activeGeneration else { return }
            self.finishPassiveCapture()
        }
    }

    private func scheduleCaptureHardStop() {
        guard hardStopTask == nil else { return }
        let activeGeneration = generation
        hardStopTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.captureMaximum)
            guard !Task.isCancelled, let self, self.generation == activeGeneration else { return }
            self.finishPassiveCapture()
        }
    }

    private func finishPassiveCapture() {
        let transcript = capturedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        stopActiveSession()
        guard !transcript.isEmpty else {
            resumePassiveIfNeeded()
            return
        }
        execute(transcript)
    }

    private func execute(_ transcript: String) {
        let template: CommandTemplate
        do {
            template = try configuration().commandTemplate
        } catch {
            state = .failed(error.localizedDescription)
            resumePassiveAfterCooldown()
            return
        }

        state = .executing
        lastTranscript = transcript
        Task { [weak self, commandRunner] in
            do {
                _ = try await commandRunner.run(template: template, transcript: transcript)
                guard let self else { return }
                self.resumePassiveAfterCooldown()
            } catch {
                guard let self else { return }
                self.state = .failed(error.localizedDescription)
                self.resumePassiveAfterCooldown()
            }
        }
    }

    private func resumePassiveAfterCooldown() {
        restartTask?.cancel()
        restartTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.executionCooldown)
            guard !Task.isCancelled, let self else { return }
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
        generation &+= 1
        inactivityTask?.cancel()
        inactivityTask = nil
        hardStopTask?.cancel()
        hardStopTask = nil
        speechSession.stop()
    }
}

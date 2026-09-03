import AppKit
import AVFoundation
import VoiceActivationCore

@MainActor
protocol AgentConversationAudioPlaying: AnyObject {
    var onSpeakingChange: ((Bool) -> Void)? { get set }

    func setWorking(_ working: Bool)
    func speak(_ text: String, localeID: String)
    func stopSpeaking()
    func stopAll()
}

@MainActor
final class SystemAgentConversationAudioPlayer: AgentConversationAudioPlaying {
    var onSpeakingChange: ((Bool) -> Void)?

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var speechMonitorTask: Task<Void, Never>?
    private var workingTask: Task<Void, Never>?
    private var workingSound: NSSound?
    private var isWorking = false
    private var isReportingSpeech = false

    func setWorking(_ working: Bool) {
        if !working, !isWorking { return }
        isWorking = working
        workingTask?.cancel()
        workingTask = nil
        guard working else { return }

        workingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1.6))
            } catch {
                return
            }

            while !Task.isCancelled, let self, self.isWorking {
                self.playWorkingPulse()
                do {
                    try await Task.sleep(for: .seconds(3.2))
                } catch {
                    return
                }
            }
        }
    }

    func speak(_ text: String, localeID: String) {
        let value = String(text.prefix(20_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        stopSpeaking()
        let utterance = AVSpeechUtterance(string: value)
        utterance.voice = AVSpeechSynthesisVoice(language: localeID)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94
        utterance.pitchMultiplier = 1.02
        utterance.preUtteranceDelay = 0.08
        setReportingSpeech(true)
        speechSynthesizer.speak(utterance)
        speechMonitorTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            while !Task.isCancelled, let self, self.speechSynthesizer.isSpeaking {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.speechMonitorTask = nil
            self.setReportingSpeech(false)
        }
    }

    func stopSpeaking() {
        speechMonitorTask?.cancel()
        speechMonitorTask = nil
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        setReportingSpeech(false)
    }

    func stopAll() {
        setWorking(false)
        stopSpeaking()
    }

    private func playWorkingPulse() {
        let sound: NSSound
        if let workingSound {
            sound = workingSound
        } else {
            guard let url = Bundle.main.url(forResource: "CaptureStart", withExtension: "wav"),
                  let loadedSound = NSSound(contentsOf: url, byReference: true)
            else { return }
            loadedSound.volume = 0.12
            workingSound = loadedSound
            sound = loadedSound
        }
        if sound.isPlaying {
            sound.stop()
        }
        sound.play()
    }

    private func setReportingSpeech(_ speaking: Bool) {
        guard speaking != isReportingSpeech else { return }
        isReportingSpeech = speaking
        onSpeakingChange?(speaking)
    }
}

@MainActor
final class AgentConversationAudioPresenter {
    private static let maximumReplyCharacters = 20_000

    private let player: any AgentConversationAudioPlaying
    private let readsReplies: () -> Bool
    private let playsWorkingSound: () -> Bool
    private let localeID: () -> String
    private var runID: UUID?
    private var reply = ""
    private var activityIsWorking = false

    init(
        player: any AgentConversationAudioPlaying,
        readsReplies: @escaping () -> Bool,
        playsWorkingSound: @escaping () -> Bool,
        localeID: @escaping () -> String)
    {
        self.player = player
        self.readsReplies = readsReplies
        self.playsWorkingSound = playsWorkingSound
        self.localeID = localeID
    }

    func handle(_ lifecycleEvent: AgentRunLifecycleEvent) {
        switch lifecycleEvent {
        case let .started(runID, _, _):
            self.runID = runID
            reply = ""
            player.stopSpeaking()
            updateWorking(true)
        case let .followUpSubmitted(runID, _):
            guard self.runID == runID else { return }
            reply = ""
            player.stopSpeaking()
            updateWorking(true)
        case .notice:
            break
        case let .turnStarted(runID):
            guard self.runID == runID else { return }
            reply = ""
            updateWorking(true)
        case let .turnCancellationStarted(runID):
            guard self.runID == runID else { return }
            player.stopSpeaking()
            updateWorking(false)
        case let .event(runID, event):
            guard self.runID == runID else { return }
            handle(event)
        case let .turnCompleted(runID, result):
            guard self.runID == runID else { return }
            updateWorking(false)
            guard result.stopReason != .cancelled, readsReplies() else { return }
            let spokenReply = AgentMarkdownFormatter.spokenText(from: reply)
            player.speak(spokenReply, localeID: localeID())
        case let .completed(runID, result):
            guard self.runID == runID else { return }
            activityIsWorking = false
            player.stopAll()
            self.runID = nil
            reply = ""
            if result.stopReason == .cancelled, readsReplies() {
                player.speak("Stopped.", localeID: localeID())
            }
        case let .failed(runID, _):
            guard self.runID == runID else { return }
            activityIsWorking = false
            player.stopAll()
            self.runID = nil
            reply = ""
        }
    }

    func shutdown() {
        activityIsWorking = false
        player.stopAll()
        runID = nil
        reply = ""
    }

    func refreshSettings() {
        player.setWorking(activityIsWorking && playsWorkingSound())
        if !readsReplies() {
            player.stopSpeaking()
        }
    }

    func resumeAfterPermission(runID: UUID) {
        guard self.runID == runID else { return }
        updateWorking(true)
    }

    private func handle(_ event: AgentRunEvent) {
        switch event {
        case let .agentMessageDelta(_, text):
            appendReply(text)
            updateWorking(true)
        case .permissionRequested:
            updateWorking(false)
        case .thoughtDelta, .toolCall, .toolCallUpdate, .plan, .connected:
            updateWorking(true)
        case .metadata, .diagnostic, .unknown, .deliveryNotice:
            break
        }
    }

    private func appendReply(_ text: String) {
        reply.append(text)
        if reply.count > Self.maximumReplyCharacters {
            reply = String(reply.suffix(Self.maximumReplyCharacters))
        }
    }

    private func updateWorking(_ working: Bool) {
        activityIsWorking = working
        player.setWorking(working && playsWorkingSound())
    }
}

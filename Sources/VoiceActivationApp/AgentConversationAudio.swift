// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import AVFoundation
import VoiceActivationCore

@MainActor
protocol AgentConversationAudioPlaying: AnyObject {
    var onSpeakingChange: ((Bool) -> Void)? { get set }

    func setWorking(_ working: Bool)
    func playActivitySound(_ sound: AgentActivitySound)
    func speak(_ text: String, localeID: String)
    func stopSpeaking()
    func stopAll()
}

@MainActor
protocol AgentSystemSpeechSynthesizing: AnyObject {
    var isSpeaking: Bool { get }

    func speak(_ utterance: AVSpeechUtterance)
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: AgentSystemSpeechSynthesizing {}

struct AgentSpeechConfiguration: Equatable {
    let provider: AgentSpeechProvider
    let elevenLabsAPIKey: String
    let elevenLabsVoiceID: String

    static let systemDefault = AgentSpeechConfiguration(
        provider: .system,
        elevenLabsAPIKey: "",
        elevenLabsVoiceID: "")
}

@MainActor
final class AgentConversationAudioPlayer: AgentConversationAudioPlaying {
    var onSpeakingChange: ((Bool) -> Void)?

    private let speechSynthesizer: any AgentSystemSpeechSynthesizing
    private let speechConfiguration: @MainActor () -> AgentSpeechConfiguration
    private let elevenLabsPlayer: ElevenLabsSpeechOutputPlayer
    private let activitySoundPlayer: any AgentActivitySoundPlaying
    private let workingPulseInitialDelay: Duration
    private let workingPulseInterval: Duration
    private var speechMonitorTask: Task<Void, Never>?
    private var workingTask: Task<Void, Never>?
    private var workingRequested = false
    private var nativeSpeechIsActive = false
    private var elevenLabsSpeechIsActive = false
    private var isReportingSpeech = false

    init(
        speechSynthesizer: any AgentSystemSpeechSynthesizing = AVSpeechSynthesizer(),
        speechConfiguration: @escaping @MainActor () -> AgentSpeechConfiguration = {
            .systemDefault
        },
        elevenLabsSynthesizer: any ElevenLabsSpeechSynthesizing = ElevenLabsSpeechClient(),
        elevenLabsAudioPlayer: any AgentAudioDataPlaying = SystemAgentAudioDataPlayer(),
        activitySoundPlayer: any AgentActivitySoundPlaying = SystemAgentActivitySoundPlayer(),
        workingPulseInitialDelay: Duration = .seconds(1.6),
        workingPulseInterval: Duration = .seconds(3.2))
    {
        self.speechSynthesizer = speechSynthesizer
        self.speechConfiguration = speechConfiguration
        elevenLabsPlayer = ElevenLabsSpeechOutputPlayer(
            synthesizer: elevenLabsSynthesizer,
            audioPlayer: elevenLabsAudioPlayer)
        self.activitySoundPlayer = activitySoundPlayer
        self.workingPulseInitialDelay = workingPulseInitialDelay
        self.workingPulseInterval = workingPulseInterval
        elevenLabsPlayer.onSpeakingChange = { [weak self] speaking in
            self?.elevenLabsSpeechChanged(speaking)
        }
        elevenLabsPlayer.onFailure = { [weak self] text, localeID in
            self?.speakWithSystemVoice(text, localeID: localeID)
        }
    }

    func setWorking(_ working: Bool) {
        guard workingRequested != working else { return }
        workingRequested = working
        if working, !isReportingSpeech {
            startWorkingPulseImmediately()
        } else {
            refreshWorkingPulse()
        }
    }

    func playActivitySound(_ sound: AgentActivitySound) {
        guard !isReportingSpeech else { return }
        workingTask?.cancel()
        workingTask = nil
        activitySoundPlayer.play(sound)
        scheduleWorkingPulseIfNeeded()
    }

    func speak(_ text: String, localeID: String) {
        let value = String(text.prefix(20_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        let configuration = speechConfiguration()
        if configuration.provider == .elevenLabs,
           !configuration.elevenLabsAPIKey.isEmpty,
           !configuration.elevenLabsVoiceID.isEmpty
        {
            elevenLabsPlayer.speak(
                value,
                apiKey: configuration.elevenLabsAPIKey,
                voiceID: configuration.elevenLabsVoiceID,
                localeID: localeID)
            return
        }

        speakWithSystemVoice(value, localeID: localeID)
    }

    func stopSpeaking() {
        speechMonitorTask?.cancel()
        speechMonitorTask = nil
        if speechSynthesizer.isSpeaking {
            _ = speechSynthesizer.stopSpeaking(at: .immediate)
        }
        nativeSpeechIsActive = false
        elevenLabsPlayer.stop()
        updateReportingSpeech()
    }

    func stopAll() {
        workingRequested = false
        refreshWorkingPulse()
        stopSpeaking()
    }

    private func refreshWorkingPulse() {
        workingTask?.cancel()
        workingTask = nil
        activitySoundPlayer.stop()
        scheduleWorkingPulseIfNeeded()
    }

    private func startWorkingPulseImmediately() {
        workingTask?.cancel()
        workingTask = nil
        activitySoundPlayer.stop()
        guard workingRequested, !isReportingSpeech else { return }
        activitySoundPlayer.play(.thinking)
        scheduleWorkingPulseIfNeeded(after: workingPulseInterval)
    }

    private func scheduleWorkingPulseIfNeeded(after delay: Duration? = nil) {
        guard workingRequested, !isReportingSpeech else { return }

        workingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: delay ?? self.workingPulseInitialDelay)
            } catch {
                return
            }

            while !Task.isCancelled, self.workingRequested, !self.isReportingSpeech {
                self.activitySoundPlayer.play(.thinking)
                do {
                    try await Task.sleep(for: self.workingPulseInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func speakWithSystemVoice(_ value: String, localeID: String) {
        let utterance = AVSpeechUtterance(string: value)
        utterance.voice = AVSpeechSynthesisVoice(language: localeID)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94
        utterance.pitchMultiplier = 1.02
        utterance.preUtteranceDelay = 0.08
        nativeSpeechIsActive = true
        updateReportingSpeech()
        speechSynthesizer.speak(utterance)
        guard speechMonitorTask == nil else { return }
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
            self.nativeSpeechIsActive = false
            self.updateReportingSpeech()
        }
    }

    private func elevenLabsSpeechChanged(_ speaking: Bool) {
        elevenLabsSpeechIsActive = speaking
        updateReportingSpeech()
    }

    private func updateReportingSpeech() {
        let speaking = nativeSpeechIsActive || elevenLabsSpeechIsActive
        guard speaking != isReportingSpeech else { return }
        isReportingSpeech = speaking
        refreshWorkingPulse()
        onSpeakingChange?(speaking)
    }
}

@MainActor
final class AgentConversationAudioPresenter {
    private static let maximumReplyCharacters = 20_000
    private static let speechFlushDelay = Duration.milliseconds(350)

    private let player: any AgentConversationAudioPlaying
    private let readsReplies: () -> Bool
    private let playsWorkingSound: () -> Bool
    private let localeID: () -> String
    private var runID: UUID?
    private var reply = ""
    private var activityIsWorking = false
    private var toolSoundPhases: [String: ToolSoundPhase] = [:]
    private var speechFlushTask: Task<Void, Never>?

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
            cancelSpeechFlush()
            self.runID = runID
            reply = ""
            toolSoundPhases.removeAll(keepingCapacity: true)
            player.stopSpeaking()
            updateWorking(true)
        case let .followUpSubmitted(runID, _):
            guard self.runID == runID else { return }
            cancelSpeechFlush()
            reply = ""
            toolSoundPhases.removeAll(keepingCapacity: true)
            player.stopSpeaking()
            updateWorking(true)
        case .notice:
            break
        case let .turnStarted(runID):
            guard self.runID == runID else { return }
            cancelSpeechFlush()
            reply = ""
            toolSoundPhases.removeAll(keepingCapacity: true)
            updateWorking(true)
        case let .turnCancellationStarted(runID):
            guard self.runID == runID else { return }
            cancelSpeechFlush()
            player.stopSpeaking()
            updateWorking(false)
        case let .event(runID, event):
            guard self.runID == runID else { return }
            handle(event)
        case let .turnCompleted(runID, result):
            guard self.runID == runID else { return }
            cancelSpeechFlush()
            updateWorking(false)
            let remainingReply = reply
            reply = ""
            guard result.stopReason != .cancelled, readsReplies() else { return }
            speak(remainingReply)
        case let .turnFailed(runID, _):
            guard self.runID == runID else { return }
            cancelSpeechFlush()
            updateWorking(false)
            let remainingReply = reply
            reply = ""
            guard readsReplies() else { return }
            speak(remainingReply)
        case let .completed(runID, result):
            guard self.runID == runID else { return }
            cancelSpeechFlush()
            activityIsWorking = false
            player.stopAll()
            self.runID = nil
            reply = ""
            toolSoundPhases.removeAll(keepingCapacity: true)
            if result.stopReason == .cancelled, readsReplies() {
                player.speak("Stopped.", localeID: localeID())
            }
        case let .failed(runID, _):
            guard self.runID == runID else { return }
            cancelSpeechFlush()
            activityIsWorking = false
            player.stopAll()
            self.runID = nil
            reply = ""
            toolSoundPhases.removeAll(keepingCapacity: true)
        }
    }

    func shutdown() {
        cancelSpeechFlush()
        activityIsWorking = false
        player.stopAll()
        runID = nil
        reply = ""
        toolSoundPhases.removeAll(keepingCapacity: true)
    }

    func refreshSettings() {
        player.setWorking(activityIsWorking && playsWorkingSound())
        if !readsReplies() {
            cancelSpeechFlush()
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
            speakReadyReply()
            boundReplyBuffer()
            scheduleSpeechFlush()
            updateWorking(true)
        case .permissionRequested:
            updateWorking(false)
        case let .toolCall(tool):
            handleToolSound(id: tool.id, status: tool.status)
            updateWorking(true)
        case let .toolCallUpdate(tool):
            handleToolSound(id: tool.id, status: tool.status)
            updateWorking(true)
        case .thoughtDelta, .plan, .connected:
            updateWorking(true)
        case .metadata, .diagnostic, .unknown, .deliveryNotice:
            break
        }
    }

    private func appendReply(_ text: String) {
        reply.append(text)
    }

    private func handleToolSound(id: String, status: AgentToolCallStatus?) {
        let phase = ToolSoundPhase(status: status)
        guard toolSoundPhases[id] != phase else { return }
        toolSoundPhases[id] = phase
        guard playsWorkingSound() else { return }
        player.playActivitySound(phase.sound)
    }

    private func speakReadyReply() {
        guard readsReplies() else { return }
        while let boundary = Self.firstSpeechBoundary(in: reply) {
            let chunk = String(reply[..<boundary])
            reply.removeSubrange(..<boundary)
            speak(chunk)
        }
    }

    private func speak(_ markdown: String) {
        let spokenText = AgentMarkdownFormatter.spokenText(from: markdown)
        guard !spokenText.isEmpty else { return }
        player.speak(spokenText, localeID: localeID())
    }

    private func boundReplyBuffer() {
        guard reply.count > Self.maximumReplyCharacters else { return }
        if let activeFence = Self.unclosedFenceMarker(in: reply) {
            reply = "\(activeFence)\n"
            return
        }
        reply = String(reply.suffix(Self.maximumReplyCharacters))
    }

    private func scheduleSpeechFlush() {
        guard speechFlushTask == nil,
              readsReplies(), !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.unclosedFenceMarker(in: reply) == nil,
              let runID
        else { return }

        speechFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.speechFlushDelay)
            } catch {
                return
            }
            guard let self, self.runID == runID, self.readsReplies() else { return }
            self.speechFlushTask = nil
            guard Self.unclosedFenceMarker(in: self.reply) == nil else { return }
            let pendingReply = self.reply
            self.reply = ""
            self.speak(pendingReply)
        }
    }

    private func cancelSpeechFlush() {
        speechFlushTask?.cancel()
        speechFlushTask = nil
    }

    private enum ToolSoundPhase: Equatable {
        case active
        case completed
        case failed

        init(status: AgentToolCallStatus?) {
            switch status {
            case .completed:
                self = .completed
            case .failed:
                self = .failed
            case .pending, .inProgress, nil:
                self = .active
            }
        }

        var sound: AgentActivitySound {
            switch self {
            case .active: .toolStarted
            case .completed: .toolCompleted
            case .failed: .toolFailed
            }
        }
    }

    private static func firstSpeechBoundary(in text: String) -> String.Index? {
        var activeFence: String?
        var lineStart = text.startIndex

        while lineStart < text.endIndex {
            let newline = text[lineStart...].firstIndex(of: "\n")
            let lineEnd = newline ?? text.endIndex
            let trimmedLine = text[lineStart..<lineEnd]
                .drop(while: { $0 == " " || $0 == "\t" })
            let wasInsideFence = activeFence != nil

            if let fence = activeFence {
                if trimmedLine.hasPrefix(fence) {
                    activeFence = nil
                }
            } else if let fence = fenceMarker(in: trimmedLine) {
                activeFence = fence
            }

            if !wasInsideFence, activeFence == nil {
                var index = lineStart
                while index < lineEnd {
                    let character = text[index]
                    let boundary = text.index(after: index)
                    if (character == "." || character == "!" || character == "?"),
                       boundary == lineEnd || text[boundary].isWhitespace
                    {
                        return boundary
                    }
                    index = boundary
                }
            }

            guard let newline else { break }
            let boundary = text.index(after: newline)
            if activeFence == nil {
                return boundary
            }
            lineStart = boundary
        }
        return nil
    }

    private static func unclosedFenceMarker(in text: String) -> String? {
        var activeFence: String?
        var lineStart = text.startIndex

        while lineStart < text.endIndex {
            let newline = text[lineStart...].firstIndex(of: "\n")
            let lineEnd = newline ?? text.endIndex
            let trimmedLine = text[lineStart..<lineEnd]
                .drop(while: { $0 == " " || $0 == "\t" })

            if let fence = activeFence {
                if trimmedLine.hasPrefix(fence) {
                    activeFence = nil
                }
            } else if let fence = fenceMarker(in: trimmedLine) {
                activeFence = fence
            }

            guard let newline else { break }
            lineStart = text.index(after: newline)
        }

        return activeFence
    }

    private static func fenceMarker(in line: Substring) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private func updateWorking(_ working: Bool) {
        activityIsWorking = working
        player.setWorking(working && playsWorkingSound())
    }
}

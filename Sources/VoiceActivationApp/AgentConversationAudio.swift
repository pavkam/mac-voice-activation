// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
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
final class AgentConversationAudioOrchestrator: AgentConversationAudioPlaying {
    var onSpeakingChange: ((Bool) -> Void)?

    private let speechConfiguration: @MainActor () -> AgentSpeechConfiguration
    private let speechQueue: any AgentSpeechQueueing
    private let activityLoop: any AgentActivitySoundLooping
    private var isReportingSpeech = false

    init(
        speechConfiguration: @escaping @MainActor () -> AgentSpeechConfiguration = {
            .systemDefault
        },
        elevenLabsSynthesizer: any ElevenLabsSpeechSynthesizing = ElevenLabsSpeechClient(),
        elevenLabsAudioPlayer: any AgentAudioDataPlaying = SystemAgentAudioDataPlayer(),
        systemSpeechPlayer: any AgentSystemSpeechPlaying = SystemAgentSpeechPlayer(),
        activitySoundPlayer: any AgentActivitySoundPlaying = SystemAgentActivitySoundPlayer(),
        workingPulseInitialDelay: Duration = .seconds(1.6),
        workingPulseInterval: Duration = .seconds(3.2))
    {
        self.speechConfiguration = speechConfiguration
        speechQueue = AgentSpeechQueue(
            synthesizer: elevenLabsSynthesizer,
            audioPlayer: elevenLabsAudioPlayer,
            systemSpeechPlayer: systemSpeechPlayer)
        activityLoop = AgentActivitySoundLoop(
            player: activitySoundPlayer,
            initialDelay: workingPulseInitialDelay,
            interval: workingPulseInterval)
        observeSpeechQueue()
    }

    init(
        speechConfiguration: @escaping @MainActor () -> AgentSpeechConfiguration,
        speechQueue: any AgentSpeechQueueing,
        activityLoop: any AgentActivitySoundLooping)
    {
        self.speechConfiguration = speechConfiguration
        self.speechQueue = speechQueue
        self.activityLoop = activityLoop
        observeSpeechQueue()
    }

    func setWorking(_ working: Bool) {
        activityLoop.setWorking(working)
    }

    func playActivitySound(_ sound: AgentActivitySound) {
        activityLoop.play(sound)
    }

    func speak(_ text: String, localeID: String) {
        let value = String(text.prefix(20_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        speechQueue.enqueue(AgentSpeechRequest(
            text: value,
            localeID: localeID,
            configuration: speechConfiguration()))
    }

    func stopSpeaking() {
        speechQueue.stop()
    }

    func stopAll() {
        activityLoop.stop()
        speechQueue.stop()
    }

    private func observeSpeechQueue() {
        speechQueue.onStateChange = { [weak self] state in
            self?.speechStateChanged(state)
        }
    }

    private func speechStateChanged(_ state: AgentSpeechQueueState) {
        activityLoop.setSpeechSuppressed(state == .starting || state == .playing)
        let speaking = state == .playing
        guard speaking != isReportingSpeech else { return }
        isReportingSpeech = speaking
        onSpeakingChange?(speaking)
    }
}

@MainActor
final class AgentConversationAudioPresenter {
    private let player: any AgentConversationAudioPlaying
    private let readsReplies: () -> Bool
    private let playsWorkingSound: () -> Bool
    private let localeID: () -> String
    private let narration: AgentNarrationSegmenter
    private var runID: UUID?
    private var activityIsWorking = false
    private var toolSoundPhases: [String: ToolSoundPhase] = [:]

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
        narration = AgentNarrationSegmenter()
        narration.onSegment = { [player] text in
            guard readsReplies() else { return }
            player.speak(text, localeID: localeID())
        }
    }

    func handle(_ lifecycleEvent: AgentRunLifecycleEvent) {
        switch lifecycleEvent {
        case let .started(runID, _, _):
            narration.reset()
            self.runID = runID
            toolSoundPhases.removeAll(keepingCapacity: true)
            player.stopSpeaking()
            updateWorking(true)
        case let .followUpSubmitted(runID, _):
            guard self.runID == runID else { return }
            narration.reset()
            toolSoundPhases.removeAll(keepingCapacity: true)
            player.stopSpeaking()
            updateWorking(true)
        case .notice:
            break
        case let .turnStarted(runID):
            guard self.runID == runID else { return }
            narration.reset()
            toolSoundPhases.removeAll(keepingCapacity: true)
            updateWorking(true)
        case let .turnCancellationStarted(runID):
            guard self.runID == runID else { return }
            narration.reset()
            player.stopSpeaking()
            updateWorking(false)
        case let .event(runID, event):
            guard self.runID == runID else { return }
            handle(event)
        case let .turnCompleted(runID, result):
            guard self.runID == runID else { return }
            if result.stopReason == .cancelled {
                narration.reset()
                player.stopSpeaking()
            } else if readsReplies() {
                narration.finish()
            } else {
                narration.reset()
            }
            updateWorking(false)
        case let .turnFailed(runID, _):
            guard self.runID == runID else { return }
            if readsReplies() {
                narration.finish()
            } else {
                narration.reset()
            }
            updateWorking(false)
        case let .completed(runID, result):
            guard self.runID == runID else { return }
            narration.reset()
            activityIsWorking = false
            player.stopAll()
            self.runID = nil
            toolSoundPhases.removeAll(keepingCapacity: true)
            if result.stopReason == .cancelled, readsReplies() {
                player.speak("Stopped.", localeID: localeID())
            }
        case let .failed(runID, _):
            guard self.runID == runID else { return }
            narration.reset()
            activityIsWorking = false
            player.stopAll()
            self.runID = nil
            toolSoundPhases.removeAll(keepingCapacity: true)
        }
    }

    func shutdown() {
        narration.reset()
        activityIsWorking = false
        player.stopAll()
        runID = nil
        toolSoundPhases.removeAll(keepingCapacity: true)
    }

    func refreshSettings() {
        player.setWorking(activityIsWorking && playsWorkingSound())
        if !readsReplies() {
            narration.reset()
            player.stopSpeaking()
        }
    }

    func resumeAfterPermission(runID: UUID) {
        guard self.runID == runID else { return }
        updateWorking(true)
    }

    private func handle(_ event: AgentRunEvent) {
        switch event {
        case let .agentMessageDelta(messageID, text):
            if readsReplies() {
                narration.append(messageID: messageID, text: text)
            }
            updateWorking(true)
        case .permissionRequested:
            narration.markSemanticBoundary()
            updateWorking(false)
        case let .toolCall(tool):
            narration.markSemanticBoundary()
            handleToolSound(id: tool.id, status: tool.status)
            updateWorking(true)
        case let .toolCallUpdate(tool):
            narration.markSemanticBoundary()
            handleToolSound(id: tool.id, status: tool.status)
            updateWorking(true)
        case .thoughtDelta, .plan, .connected:
            narration.markSemanticBoundary()
            updateWorking(true)
        case .metadata, .diagnostic, .unknown, .deliveryNotice:
            break
        }
    }

    private func handleToolSound(id: String, status: AgentToolCallStatus?) {
        let phase = ToolSoundPhase(status: status)
        guard toolSoundPhases[id] != phase else { return }
        toolSoundPhases[id] = phase
        guard playsWorkingSound() else { return }
        player.playActivitySound(phase.sound)
    }

    private func updateWorking(_ working: Bool) {
        activityIsWorking = working
        player.setWorking(working && playsWorkingSound())
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
}

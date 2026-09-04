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
    private let diagnostics: any VoiceActivationDiagnosticRecording
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
        workingPulseInterval: Duration = .seconds(3.2),
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.speechConfiguration = speechConfiguration
        self.diagnostics = diagnostics
        speechQueue = AgentSpeechQueue(
            synthesizer: elevenLabsSynthesizer,
            audioPlayer: elevenLabsAudioPlayer,
            systemSpeechPlayer: systemSpeechPlayer,
            diagnostics: diagnostics)
        activityLoop = AgentActivitySoundLoop(
            player: activitySoundPlayer,
            initialDelay: workingPulseInitialDelay,
            interval: workingPulseInterval,
            diagnostics: diagnostics)
        observeSpeechQueue()
    }

    init(
        speechConfiguration: @escaping @MainActor () -> AgentSpeechConfiguration,
        speechQueue: any AgentSpeechQueueing,
        activityLoop: any AgentActivitySoundLooping,
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.speechConfiguration = speechConfiguration
        self.speechQueue = speechQueue
        self.activityLoop = activityLoop
        self.diagnostics = diagnostics
        observeSpeechQueue()
    }

    func setWorking(_ working: Bool) {
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.working_requested",
            fields: ["working": String(working)])
        activityLoop.setWorking(working)
    }

    func playActivitySound(_ sound: AgentActivitySound) {
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.activity_sound_requested",
            fields: ["sound": sound.audioDiagnosticName])
        activityLoop.play(sound)
    }

    func speak(_ text: String, localeID: String) {
        let value = String(text.prefix(20_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            diagnostics.record(
                category: .audio,
                event: "conversation_audio.speech_ignored",
                fields: ["reason": "empty"])
            return
        }
        let configuration = speechConfiguration()
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.speech_enqueued",
            fields: [
                "character_count": String(value.count),
                "provider": configuration.provider.rawValue,
            ])
        speechQueue.enqueue(
            AgentSpeechRequest(
                text: value,
                localeID: localeID,
                configuration: configuration))
    }

    func stopSpeaking() {
        diagnostics.record(category: .audio, event: "conversation_audio.speech_stop_requested")
        speechQueue.stop()
    }

    func stopAll() {
        diagnostics.record(category: .audio, event: "conversation_audio.stop_all_requested")
        activityLoop.stop()
        speechQueue.stop()
    }

    private func observeSpeechQueue() {
        speechQueue.onStateChange = { [weak self] state in
            self?.speechStateChanged(state)
        }
    }

    private func speechStateChanged(_ state: AgentSpeechQueueState) {
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.speech_state_received",
            fields: ["state": String(describing: state)])
        activityLoop.setSpeechSuppressed(state == .starting || state == .playing)
        let speaking = state == .playing
        guard speaking != isReportingSpeech else { return }
        isReportingSpeech = speaking
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.audibility_changed",
            fields: ["audible": String(speaking)])
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
    private let diagnostics: any VoiceActivationDiagnosticRecording
    private var runID: UUID?
    private var activityIsWorking = false
    private var toolSoundPhases: [String: ToolSoundPhase] = [:]

    init(
        player: any AgentConversationAudioPlaying,
        readsReplies: @escaping () -> Bool,
        playsWorkingSound: @escaping () -> Bool,
        localeID: @escaping () -> String,
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.player = player
        self.readsReplies = readsReplies
        self.playsWorkingSound = playsWorkingSound
        self.localeID = localeID
        self.diagnostics = diagnostics
        narration = AgentNarrationSegmenter(diagnostics: diagnostics)
        narration.onSegment = { [player] text in
            guard readsReplies() else {
                diagnostics.record(
                    category: .audio,
                    event: "conversation_audio.segment_suppressed",
                    fields: ["reason": "read_replies_disabled"])
                return
            }
            player.speak(text, localeID: localeID())
        }
    }

    func handle(_ lifecycleEvent: AgentRunLifecycleEvent) {
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.lifecycle_received",
            fields: lifecycleEvent.audioDiagnosticFields)
        switch lifecycleEvent {
        case .started(let runID, _, _):
            narration.reset()
            self.runID = runID
            toolSoundPhases.removeAll(keepingCapacity: true)
            player.stopSpeaking()
            updateWorking(true)
        case .followUpSubmitted(let runID, _):
            guard self.runID == runID else { return }
            narration.reset()
            toolSoundPhases.removeAll(keepingCapacity: true)
            player.stopSpeaking()
            updateWorking(true)
        case .notice:
            break
        case .turnStarted(let runID):
            guard self.runID == runID else { return }
            narration.reset()
            toolSoundPhases.removeAll(keepingCapacity: true)
            updateWorking(true)
        case .turnCancellationStarted(let runID):
            guard self.runID == runID else { return }
            narration.reset()
            player.stopSpeaking()
            updateWorking(false)
        case .event(let runID, let event):
            guard self.runID == runID else { return }
            handle(event)
        case .turnCompleted(let runID, let result):
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
        case .turnFailed(let runID, _):
            guard self.runID == runID else { return }
            if readsReplies() {
                narration.finish()
            } else {
                narration.reset()
            }
            updateWorking(false)
        case .completed(let runID, let result):
            guard self.runID == runID else { return }
            narration.reset()
            activityIsWorking = false
            player.stopAll()
            self.runID = nil
            toolSoundPhases.removeAll(keepingCapacity: true)
            if result.stopReason == .cancelled, readsReplies() {
                player.speak("Stopped.", localeID: localeID())
            }
        case .failed(let runID, _):
            guard self.runID == runID else { return }
            narration.reset()
            activityIsWorking = false
            player.stopAll()
            self.runID = nil
            toolSoundPhases.removeAll(keepingCapacity: true)
        }
    }

    func shutdown() {
        diagnostics.record(category: .audio, event: "conversation_audio.shutdown")
        narration.reset()
        activityIsWorking = false
        player.stopAll()
        runID = nil
        toolSoundPhases.removeAll(keepingCapacity: true)
    }

    func refreshSettings() {
        diagnostics.record(
            category: .settings,
            event: "conversation_audio.settings_refreshed",
            fields: [
                "reads_replies": String(readsReplies()),
                "plays_working_sound": String(playsWorkingSound()),
            ])
        player.setWorking(activityIsWorking && playsWorkingSound())
        if !readsReplies() {
            narration.reset()
            player.stopSpeaking()
        }
    }

    func resumeAfterPermission(runID: UUID) {
        guard self.runID == runID else {
            diagnostics.record(
                category: .audio,
                event: "conversation_audio.permission_resume_ignored",
                fields: ["run_id": runID.uuidString])
            return
        }
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.permission_resumed",
            fields: ["run_id": runID.uuidString])
        updateWorking(true)
    }

    private func handle(_ event: AgentRunEvent) {
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.agent_event_received",
            fields: ["event_kind": event.audioDiagnosticName])
        switch event {
        case .agentMessageDelta(let messageID, let text):
            if readsReplies() {
                narration.append(messageID: messageID, text: text)
            }
            updateWorking(true)
        case .permissionRequested:
            narration.markSemanticBoundary()
            updateWorking(false)
        case .toolCall(let tool):
            narration.markSemanticBoundary()
            handleToolSound(id: tool.id, status: tool.status)
            updateWorking(true)
        case .toolCallUpdate(let tool):
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
        guard playsWorkingSound() else {
            diagnostics.record(
                category: .audio,
                event: "conversation_audio.tool_sound_suppressed",
                fields: [
                    "tool_id": String(id.prefix(128)),
                    "phase": phase.diagnosticName,
                ])
            return
        }
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.tool_sound_emitted",
            fields: [
                "tool_id": String(id.prefix(128)),
                "phase": phase.diagnosticName,
            ])
        player.playActivitySound(phase.sound)
    }

    private func updateWorking(_ working: Bool) {
        activityIsWorking = working
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.working_changed",
            fields: [
                "working": String(working),
                "sound_enabled": String(playsWorkingSound()),
            ])
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

        var diagnosticName: String {
            switch self {
            case .active: "active"
            case .completed: "completed"
            case .failed: "failed"
            }
        }
    }
}

extension AgentActivitySound {
    fileprivate var audioDiagnosticName: String {
        switch self {
        case .thinking: "thinking"
        case .toolStarted: "tool_started"
        case .toolCompleted: "tool_completed"
        case .toolFailed: "tool_failed"
        }
    }
}

extension AgentRunLifecycleEvent {
    fileprivate var audioDiagnosticFields: [String: String] {
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
                "event_kind": event.audioDiagnosticName,
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

extension AgentRunEvent {
    fileprivate var audioDiagnosticName: String {
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

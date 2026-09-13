// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import YapOpsCore

@MainActor
protocol AgentConversationAudioPlaying: AnyObject {
    /// Reports queued or playing speech before playback can reach the microphone.
    var onSpeechOutputActiveChange: ((Bool) -> Void)? { get set }

    @discardableResult
    func beginConversation(
        profile: WakeProfile,
        readsInheritedReplies: Bool
    ) -> Bool
    func endConversation()
    func setWorking(_ working: Bool)
    func playActivitySound(_ sound: AgentActivitySound)
    func speak(
        _ text: String,
        localeID: String,
        inputFormat: AgentSpeechInputFormat,
        admissionPolicy: AgentSpeechAdmissionPolicy)
    @discardableResult
    func speakVerbatim(_ texts: [String], localeID: String) -> Bool
    func stopSpeaking()
    func stopAll()
}

@MainActor
final class AgentConversationAudioOrchestrator: AgentConversationAudioPlaying {
    var onSpeechOutputActiveChange: ((Bool) -> Void)?

    private let speechConfiguration:
        @MainActor (WakeProfile, Bool) -> AgentSpeechConfiguration?
    private let speechQueue: any AgentSpeechQueueing
    private let activityLoop: any AgentActivitySoundLooping
    private let diagnostics: any YapOpsDiagnosticRecording
    private var isReportingSpeechOutput = false
    private var activeSpeechConfiguration: AgentSpeechConfiguration?

    init(
        speechConfiguration: @escaping @MainActor (WakeProfile, Bool) -> AgentSpeechConfiguration? = {
            profile, readsInheritedReplies in
            switch profile.speechPreference {
            case .inherit:
                readsInheritedReplies ? .systemDefault : nil
            case .disabled:
                nil
            case .voice(let selection):
                AgentSpeechConfiguration(selection: selection, credential: nil)
            }
        },
        backendRegistry: TextToSpeechBackendRegistry? = nil,
        elevenLabsSynthesizer: any ElevenLabsSpeechSynthesizing = ElevenLabsSpeechClient(),
        elevenLabsAudioPlayer: any AgentAudioDataPlaying = SystemAgentAudioDataPlayer(),
        systemSpeechPlayer: any AgentSystemSpeechPlaying = SystemAgentSpeechPlayer(),
        activitySoundPlayer: any AgentActivitySoundPlaying = SystemAgentActivitySoundPlayer(),
        workingPulseInitialDelay: Duration = .seconds(1.6),
        workingPulseInterval: Duration = .seconds(3.2),
        diagnostics: any YapOpsDiagnosticRecording = YapOpsDiagnostics.shared
    ) {
        self.speechConfiguration = speechConfiguration
        self.diagnostics = diagnostics
        speechQueue = AgentSpeechQueue(
            backendRegistry: backendRegistry,
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
        speechConfiguration: @escaping @MainActor (WakeProfile, Bool) -> AgentSpeechConfiguration?,
        speechQueue: any AgentSpeechQueueing,
        activityLoop: any AgentActivitySoundLooping,
        diagnostics: any YapOpsDiagnosticRecording = YapOpsDiagnostics.shared
    ) {
        self.speechConfiguration = speechConfiguration
        self.speechQueue = speechQueue
        self.activityLoop = activityLoop
        self.diagnostics = diagnostics
        observeSpeechQueue()
    }

    @discardableResult
    func beginConversation(
        profile: WakeProfile,
        readsInheritedReplies: Bool
    ) -> Bool {
        let configuration = speechConfiguration(profile, readsInheritedReplies)
        activeSpeechConfiguration = configuration
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.profile_selected",
            fields: [
                "profile_id": profile.id.uuidString,
                "speech_enabled": String(configuration != nil),
                "backend": configuration?.selection.backendID.rawValue ?? "none",
            ])
        return configuration != nil
    }

    func endConversation() {
        activeSpeechConfiguration = nil
        diagnostics.record(category: .audio, event: "conversation_audio.profile_cleared")
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

    func speak(
        _ text: String,
        localeID: String,
        inputFormat: AgentSpeechInputFormat = .legacyMarkdown,
        admissionPolicy: AgentSpeechAdmissionPolicy = .legacyNormalized
    ) {
        let value = switch admissionPolicy {
        case .legacyNormalized:
            String(text.prefix(20_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        case .agentAuthoredVerbatim:
            text
        }
        guard !value.isEmpty else {
            diagnostics.record(
                category: .audio,
                event: "conversation_audio.speech_ignored",
                fields: ["reason": "empty"])
            return
        }
        guard let configuration = activeSpeechConfiguration else {
            diagnostics.record(
                category: .audio,
                event: "conversation_audio.speech_ignored",
                fields: ["reason": "speech_disabled"])
            return
        }
        let admitted = speechQueue.enqueue(
            AgentSpeechRequest(
                text: value,
                localeID: localeID,
                configuration: configuration,
                inputFormat: inputFormat,
                admissionPolicy: admissionPolicy))
        guard admitted else {
            diagnostics.record(
                category: .audio,
                event: "conversation_audio.speech_ignored",
                fields: ["reason": "queue_rejected"])
            return
        }
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.speech_enqueued",
            fields: [
                "character_count": String(value.count),
                "backend": configuration.selection.backendID.rawValue,
            ])
    }

    @discardableResult
    func speakVerbatim(_ texts: [String], localeID: String) -> Bool {
        guard !texts.isEmpty, texts.allSatisfy({ !$0.isEmpty }) else {
            diagnostics.record(
                category: .audio,
                event: "conversation_audio.speech_ignored",
                fields: ["reason": "empty_batch"])
            return false
        }
        guard let configuration = activeSpeechConfiguration else {
            diagnostics.record(
                category: .audio,
                event: "conversation_audio.speech_ignored",
                fields: ["reason": "speech_disabled"])
            return false
        }
        let requests = texts.map {
            AgentSpeechRequest(
                text: $0,
                localeID: localeID,
                configuration: configuration,
                inputFormat: .agentAuthoredPlainText,
                admissionPolicy: .agentAuthoredVerbatim)
        }
        guard speechQueue.enqueueVerbatimBatch(requests) else {
            diagnostics.record(
                category: .audio,
                event: "conversation_audio.speech_ignored",
                fields: ["reason": "queue_rejected"])
            return false
        }
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.speech_batch_enqueued",
            fields: [
                "utterance_count": String(texts.count),
                "character_count": String(texts.reduce(0) { $0 + $1.count }),
                "backend": configuration.selection.backendID.rawValue,
            ])
        return true
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
        let active = state != .idle
        guard active != isReportingSpeechOutput else { return }
        isReportingSpeechOutput = active
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.speech_output_changed",
            fields: ["active": String(active)])
        onSpeechOutputActiveChange?(active)
    }
}

@MainActor
final class AgentConversationAudioPresenter {
    let player: any AgentConversationAudioPlaying
    private let readsReplies: () -> Bool
    private let playsWorkingSound: () -> Bool
    let localeID: () -> String
    private let narration: AgentNarrationSegmenter
    let diagnostics: any YapOpsDiagnosticRecording
    var runID: UUID?
    var readsActiveReplies = false
    private var activityIsWorking = false
    var rejectsAgentSpeechUntilNextTurn = false
    var isCapturingSpeechInput = false
    private var toolSoundPhases: [String: ToolSoundPhase] = [:]
    var pendingPermissionNarrations: [PendingPermissionNarration] = []

    init(
        player: any AgentConversationAudioPlaying,
        readsReplies: @escaping () -> Bool,
        playsWorkingSound: @escaping () -> Bool,
        localeID: @escaping () -> String,
        diagnostics: any YapOpsDiagnosticRecording = YapOpsDiagnostics.shared
    ) {
        self.player = player
        self.readsReplies = readsReplies
        self.playsWorkingSound = playsWorkingSound
        self.localeID = localeID
        self.diagnostics = diagnostics
        narration = AgentNarrationSegmenter(diagnostics: diagnostics)
        narration.onSegment = { [weak self] text in
            guard let self, readsActiveReplies else {
                self?.diagnostics.record(
                    category: .audio,
                    event: "conversation_audio.segment_suppressed",
                    fields: ["reason": "read_replies_disabled"])
                return
            }
            player.speak(
                text,
                localeID: localeID(),
                inputFormat: .legacyMarkdown,
                admissionPolicy: .legacyNormalized)
        }
    }

    func handle(_ lifecycleEvent: AgentRunLifecycleEvent) {
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.lifecycle_received",
            fields: lifecycleEvent.audioDiagnosticFields)
        switch lifecycleEvent {
        case .started(let runID, let profile, _):
            self.runID = runID
            rejectsAgentSpeechUntilNextTurn = false
            isCapturingSpeechInput = false
            pendingPermissionNarrations.removeAll(keepingCapacity: true)
            narration.reset()
            readsActiveReplies = player.beginConversation(
                profile: profile,
                readsInheritedReplies: readsReplies())
            toolSoundPhases.removeAll(keepingCapacity: true)
            player.stopSpeaking()
            updateWorking(true)
        case .followUpSubmitted(let runID, _, _, _):
            guard self.runID == runID else { return }
            isCapturingSpeechInput = false
            pendingPermissionNarrations.removeAll(keepingCapacity: true)
            narration.reset()
            toolSoundPhases.removeAll(keepingCapacity: true)
            player.stopSpeaking()
            updateWorking(true)
        case .followUpDispositionChanged, .inputContextCaptured:
            break
        case .notice:
            break
        case .dismissedBySpeech:
            // No audio reaction of its own; the completion this always
            // precedes is what stops narration and working sounds.
            break
        case .turnStarted(let runID):
            guard self.runID == runID else { return }
            rejectsAgentSpeechUntilNextTurn = false
            isCapturingSpeechInput = false
            pendingPermissionNarrations.removeAll(keepingCapacity: true)
            narration.reset()
            toolSoundPhases.removeAll(keepingCapacity: true)
            updateWorking(true)
        case .turnCancellationStarted(let runID):
            guard self.runID == runID else { return }
            rejectsAgentSpeechUntilNextTurn = true
            pendingPermissionNarrations.removeAll(keepingCapacity: true)
            narration.reset()
            player.stopSpeaking()
            updateWorking(false)
        case .event(let runID, let event):
            guard self.runID == runID else { return }
            handle(event)
        case .historyRestorationStarted, .historyEvent,
            .historyRestorationCompleted, .historyRestorationAborted:
            break
        case .turnCompleted(let runID, let result):
            guard self.runID == runID else { return }
            pendingPermissionNarrations.removeAll(keepingCapacity: true)
            if result.stopReason == .cancelled {
                rejectsAgentSpeechUntilNextTurn = true
                narration.reset()
                player.stopSpeaking()
            } else if readsActiveReplies {
                narration.finish()
            } else {
                narration.reset()
            }
            updateWorking(false)
        case .turnFailed(let runID, _):
            guard self.runID == runID else { return }
            rejectsAgentSpeechUntilNextTurn = true
            pendingPermissionNarrations.removeAll(keepingCapacity: true)
            if readsActiveReplies {
                narration.finish()
            } else {
                narration.reset()
            }
            updateWorking(false)
        case .completed(let runID, _):
            guard self.runID == runID else { return }
            self.runID = nil
            rejectsAgentSpeechUntilNextTurn = true
            pendingPermissionNarrations.removeAll(keepingCapacity: true)
            narration.reset()
            activityIsWorking = false
            player.stopAll()
            toolSoundPhases.removeAll(keepingCapacity: true)
            readsActiveReplies = false
            player.endConversation()
        case .failed(let runID, _):
            guard self.runID == runID else { return }
            self.runID = nil
            rejectsAgentSpeechUntilNextTurn = true
            pendingPermissionNarrations.removeAll(keepingCapacity: true)
            narration.reset()
            activityIsWorking = false
            player.stopAll()
            readsActiveReplies = false
            player.endConversation()
            toolSoundPhases.removeAll(keepingCapacity: true)
        }
    }

    /// Discards buffered and queued narration before explicit push-to-talk capture.
    func interruptSpeech() {
        isCapturingSpeechInput = true
        pendingPermissionNarrations.removeAll(keepingCapacity: true)
        narration.reset()
        player.stopSpeaking()
    }

    func shutdown() {
        diagnostics.record(category: .audio, event: "conversation_audio.shutdown")
        runID = nil
        rejectsAgentSpeechUntilNextTurn = true
        pendingPermissionNarrations.removeAll(keepingCapacity: true)
        narration.reset()
        activityIsWorking = false
        player.stopAll()
        readsActiveReplies = false
        player.endConversation()
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
    }

    /// Admits only current live session-authored reply content without changing prompt work audio.
    func handleSessionEvent(_ event: AgentRunEvent, runID: UUID) {
        guard self.runID == runID, !rejectsAgentSpeechUntilNextTurn,
            !isCapturingSpeechInput else { return }
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.session_event_received",
            fields: ["event_kind": event.audioDiagnosticName])
        switch event {
        case .agentMessageDelta(let messageID, let text):
            guard readsActiveReplies else { return }
            narration.append(messageID: messageID, text: text)
        case .agentSpokenNarrationReady(_, let text):
            guard readsActiveReplies else { return }
            player.speak(
                text,
                localeID: localeID(),
                inputFormat: .agentAuthoredPlainText,
                admissionPolicy: .agentAuthoredVerbatim)
        case .connected, .userMessageDelta, .agentSpokenMessageDelta,
            .agentSpokenNarrationSuppressed, .agentDisplayMessageDelta, .thoughtDelta,
            .artifact, .toolCall, .toolCallUpdate, .backgroundTask, .plan, .metadata,
            .diagnostic, .permissionRequested, .unknown, .deliveryNotice:
            break
        }
    }

    private func handle(_ event: AgentRunEvent) {
        diagnostics.record(
            category: .audio,
            event: "conversation_audio.agent_event_received",
            fields: ["event_kind": event.audioDiagnosticName])
        switch event {
        case .userMessageDelta:
            break
        case .agentMessageDelta(let messageID, let text):
            if readsActiveReplies, !rejectsAgentSpeechUntilNextTurn, !isCapturingSpeechInput {
                narration.append(messageID: messageID, text: text)
            }
            updateWorking(true)
        case .agentSpokenMessageDelta:
            narration.markSemanticBoundary()
        case .agentDisplayMessageDelta:
            narration.markSemanticBoundary()
            updateWorking(true)
        case .agentSpokenNarrationReady(_, let text):
            guard readsActiveReplies, !rejectsAgentSpeechUntilNextTurn,
                !isCapturingSpeechInput else { return }
            player.speak(
                text,
                localeID: localeID(),
                inputFormat: .agentAuthoredPlainText,
                admissionPolicy: .agentAuthoredVerbatim)
        case .agentSpokenNarrationSuppressed:
            break
        case .permissionRequested(let request):
            narration.markSemanticBoundary()
            handlePermissionRequest(request)
        case .toolCall(let tool):
            narration.markSemanticBoundary()
            handleToolSound(id: tool.id, status: tool.status)
            updateWorking(true)
        case .toolCallUpdate(let tool):
            narration.markSemanticBoundary()
            handleToolSound(id: tool.id, status: tool.status)
            updateWorking(true)
        case .backgroundTask:
            break
        case .thoughtDelta, .artifact, .plan, .connected:
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

    func updateWorking(_ working: Bool) {
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
            case .failed, .interrupted:
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
                "event_kind": event.audioDiagnosticName,
            ]
        case .historyRestorationStarted(let runID, _, _):
            ["kind": "history_restoration_started", "run_id": runID.uuidString]
        case .historyEvent(let runID, _, let event):
            [
                "kind": "history_event", "run_id": runID.uuidString,
                "event_kind": event.audioDiagnosticName,
            ]
        case .historyRestorationCompleted(let runID, _, let activation):
            [
                "kind": "history_restoration_completed",
                "run_id": runID.uuidString,
                "activation": activation.audioDiagnosticName,
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

extension AgentRunEvent {
    fileprivate var audioDiagnosticName: String {
        switch self {
        case .connected: "connected"
        case .userMessageDelta: "user_message_delta"
        case .agentMessageDelta: "agent_message_delta"
        case .agentSpokenMessageDelta: "agent_spoken_message_delta"
        case .agentSpokenNarrationReady: "agent_spoken_narration_ready"
        case .agentSpokenNarrationSuppressed: "agent_spoken_narration_suppressed"
        case .agentDisplayMessageDelta: "agent_display_message_delta"
        case .thoughtDelta: "thought_delta"
        case .artifact: "artifact"
        case .toolCall: "tool_call"
        case .toolCallUpdate: "tool_call_update"
        case .backgroundTask: "background_task"
        case .plan: "plan"
        case .permissionRequested: "permission_requested"
        case .metadata: "metadata"
        case .diagnostic: "diagnostic"
        case .deliveryNotice: "delivery_notice"
        case .unknown: "unknown"
        }
    }
}

extension AgentSessionActivation {
    fileprivate var audioDiagnosticName: String {
        switch self {
        case .new: "new"
        case .loaded: "loaded"
        case .resumed: "resumed"
        case .freshAfterUnavailableBookmark: "fresh_after_unavailable_bookmark"
        case .freshBecauseRestorationUnsupported: "fresh_restoration_unsupported"
        }
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import VoiceActivationCore

/// Reduces ordered ACP lifecycle events into a bounded immutable UI snapshot.
///
/// Token deltas are throttled for rendering, while control events publish immediately.
/// All retained text, timeline entries, tools, and diagnostics have explicit bounds.
@MainActor
final class AgentRunPresentation {
    /// The largest retained copyable agent-response payload.
    static let maximumOutputBytes = 512 * 1_024
    static let maximumDiagnosticBytes = 16 * 1_024
    static let maximumTools = 32
    static let maximumTimelineTextBytes = 64 * 1_024
    static let maximumTimelineItems = 256
    static let maximumThinkingDetailsPerGroup = 128
    static let publicationInterval = Duration.milliseconds(50)

    /// Receives every snapshot publication on the main actor.
    var onPublication: ((AgentRunSnapshot) -> Void)?

    /// The current immutable view of the active or retained terminal conversation.
    var snapshot: AgentRunSnapshot? {
        guard let runID, let profileID, let accent, let prompt, let providerName, let phase else {
            return nil
        }
        return AgentRunSnapshot(
            runID: runID,
            profileID: profileID,
            accent: accent,
            prompt: prompt,
            providerName: providerName,
            phase: phase,
            voiceInput: voiceInput,
            output: outputBuffer.value,
            timeline: timeline,
            diagnostics: diagnosticBuffer.value,
            plan: plan,
            tools: tools,
            permissions: permissions,
            notices: notices,
            elapsedSeconds: elapsedSeconds,
            evictedToolCount: evictedToolCount,
            ignoredToolUpdateCount: ignoredToolUpdateCount)
    }

    let startsElapsedTimer: Bool
    let elapsedTickInterval: Duration
    let diagnosticsRecorder: any VoiceActivationDiagnosticRecording
    let clock = ContinuousClock()
    var runID: UUID?
    var profileID: UUID?
    var accent: WakeProfileAccent?
    var prompt: String?
    var providerName: String?
    var phase: AgentRunPhase?
    var voiceInput = ""
    var needsResponseSeparator = false
    var outputBuffer = AgentRunBoundedTextBuffer(
        maximumBytes: maximumOutputBytes,
        marker: "… earlier output omitted …\n")
    var diagnosticBuffer = AgentRunBoundedTextBuffer(
        maximumBytes: maximumDiagnosticBytes,
        marker: "… earlier diagnostics omitted …\n")
    var plan: [AgentPlanEntry] = []
    var tools: [AgentToolPresentation] = []
    var timeline: [AgentRunTimelineItem] = []
    var timelineHasOmittedActivity = false
    var permissions: [AgentPermissionPresentation] = []
    var notices: [String] = []
    var elapsedSeconds = 0
    var evictedToolCount: UInt64 = 0
    var ignoredToolUpdateCount: UInt64 = 0
    var startedAt: ContinuousClock.Instant?
    var lastPublicationAt: ContinuousClock.Instant?
    var publicationIsPending = false
    var trailingPublicationTask: Task<Void, Never>?
    var trailingPublicationGeneration: UInt64 = 0
    var elapsedTask: Task<Void, Never>?
    var elapsedTaskGeneration: UInt64 = 0

    /// Creates the reducer with optional wall-clock updates for deterministic tests.
    ///
    /// - Parameters:
    ///   - startsElapsedTimer: Whether newly started turns publish elapsed ticks.
    ///   - elapsedTickInterval: The monotonic interval between elapsed publications.
    ///   - diagnostics: The privacy-safe recorder for presentation lifecycle events.
    init(
        startsElapsedTimer: Bool = true,
        elapsedTickInterval: Duration = .seconds(1),
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.startsElapsedTimer = startsElapsedTimer
        self.elapsedTickInterval = elapsedTickInterval
        diagnosticsRecorder = diagnostics
    }

    /// Replaces retained state with a newly started conversation.
    func start(runID: UUID, profile: WakeProfile, prompt: String) {
        diagnosticsRecorder.record(
            category: .ui,
            event: "agent_presentation.started",
            fields: [
                "run_id": runID.uuidString,
                "profile_id": profile.id.uuidString,
                "input_character_count": String(prompt.count),
            ])
        cancelTimers()
        self.runID = runID
        profileID = profile.id
        accent = profile.accent
        self.prompt = prompt
        if case .agent(let configuration) = profile.action {
            providerName = configuration.displayName
        } else {
            providerName = "Agent"
        }
        phase = .running
        voiceInput = ""
        needsResponseSeparator = false
        outputBuffer.removeAll()
        diagnosticBuffer.removeAll()
        plan = []
        tools = []
        timeline = []
        _ = activeThinkingGroup()
        timelineHasOmittedActivity = false
        permissions = []
        notices = []
        elapsedSeconds = 0
        evictedToolCount = 0
        ignoredToolUpdateCount = 0
        startedAt = clock.now
        lastPublicationAt = nil
        publicationIsPending = false
        publishNow()
        if startsElapsedTimer {
            startElapsedTimer(runID: runID)
        }
    }

    /// Applies one ordered ACP event when it belongs to the active nonterminal run.
    func receive(runID: UUID, event: AgentRunEvent) {
        guard self.runID == runID, phase?.isTerminal == false else {
            diagnosticsRecorder.record(
                category: .ui,
                event: "agent_presentation.event_ignored",
                level: .debug,
                fields: [
                    "run_id": runID.uuidString,
                    "event_kind": event.presentationDiagnosticName,
                ])
            return
        }
        diagnosticsRecorder.record(
            category: .ui,
            event: "agent_presentation.event_received",
            level: event.isTokenDelta ? .debug : .info,
            fields: [
                "run_id": runID.uuidString,
                "event_kind": event.presentationDiagnosticName,
                "delta_character_count": String(event.presentationCharacterCount),
                "task_priority": String(Task.currentPriority.rawValue),
            ])
        if event.isTokenDelta {
            apply(event)
            publishTokenUpdate(runID: runID)
            return
        }

        flushPendingPublication()
        apply(event)
        publishNow()
    }

    /// Appends a user follow-up after settling the preceding thinking group.
    func submitFollowUp(runID: UUID, prompt: String) {
        guard self.runID == runID, phase?.isTerminal == false else { return }
        diagnosticsRecorder.record(
            category: .ui,
            event: "agent_presentation.follow_up_added",
            fields: [
                "run_id": runID.uuidString,
                "input_character_count": String(prompt.count),
            ])
        flushPendingPublication()
        settleActiveThinkingGroup()
        timeline.append(.userMessage(AgentUserMessagePresentation(id: UUID(), text: prompt)))
        voiceInput = ""
        enforceTimelineBounds()
        publishNow()
    }

    /// Appends a bounded local lifecycle notice to the active conversation.
    func receiveNotice(runID: UUID, message: String) {
        guard self.runID == runID, phase?.isTerminal == false, !message.isEmpty else { return }
        diagnosticsRecorder.record(
            category: .ui,
            event: "agent_presentation.notice_added",
            fields: [
                "run_id": runID.uuidString,
                "character_count": String(message.count),
            ])
        flushPendingPublication()
        appendNotice(message)
        publishNow()
    }

    /// Opens a fresh thinking group for the next prompt in the conversation.
    func beginTurn(runID: UUID) {
        guard self.runID == runID, phase?.isTerminal == false else { return }
        diagnosticsRecorder.record(
            category: .ui,
            event: "agent_presentation.turn_started",
            fields: ["run_id": runID.uuidString])
        flushPendingPublication()
        phase = .running
        needsResponseSeparator = !outputBuffer.value.isEmpty
        plan = []
        permissions = []
        voiceInput = ""
        _ = activeThinkingGroup()
        publishNow()
        if startsElapsedTimer {
            startElapsedTimer(runID: runID)
        }
    }

    /// Settles the current turn and returns the conversation to follow-up listening.
    func completeTurn(runID: UUID, result _: AgentRunResult) {
        guard self.runID == runID, phase?.isTerminal == false else { return }
        diagnosticsRecorder.record(
            category: .ui,
            event: "agent_presentation.turn_completed",
            fields: ["run_id": runID.uuidString])
        flushPendingPublication()
        settleTools()
        stopElapsedTimer()
        phase = .listening
        permissions = []
        voiceInput = ""
        publishNow()
    }

    /// Preserves streamed output after a provider disconnect and allows a fresh follow-up.
    func interruptTurn(runID: UUID, message: String) {
        guard self.runID == runID, phase?.isTerminal == false else { return }
        diagnosticsRecorder.record(
            category: .ui,
            event: "agent_presentation.turn_interrupted",
            level: .error,
            fields: [
                "run_id": runID.uuidString,
                "error_character_count": String(message.count),
            ])
        flushPendingPublication()
        settleTools()
        stopElapsedTimer()
        phase = .listening
        permissions = []
        voiceInput = ""
        diagnosticBuffer.append("[turn interrupted] \(message)\n")
        appendNotice(
            "The provider disconnected after producing output. "
                + "Your next message starts a fresh session.")
        publishNow()
    }

    /// Publishes the live follow-up transcript without adding it to conversation history.
    func updateVoiceInput(runID: UUID, transcript: String) {
        guard self.runID == runID, phase?.isTerminal == false, voiceInput != transcript else {
            return
        }
        diagnosticsRecorder.record(
            category: .ui,
            event: "agent_presentation.voice_input_updated",
            level: .debug,
            fields: [
                "run_id": runID.uuidString,
                "input_character_count": String(transcript.count),
            ])
        voiceInput = transcript
        publishNow()
    }

    @discardableResult
    /// Atomically marks a pending permission as resolving.
    ///
    /// - Returns: Whether the request still existed and was eligible for one response.
    func beginPermissionResolution(runID: UUID, key: AgentPermissionKey) -> Bool {
        guard self.runID == runID,
            phase == .running,
            let index = permissions.firstIndex(where: { $0.key == key }),
            !permissions[index].isResolving
        else { return false }

        diagnosticsRecorder.record(
            category: .ui,
            event: "agent_presentation.permission_collapsed",
            fields: ["run_id": runID.uuidString])
        permissions.remove(at: index)
        flushPendingPublication()
        publishNow()
        return true
    }

    @discardableResult
    /// Moves an active run to cancelling exactly once.
    ///
    /// - Returns: Whether cancellation should be forwarded to the coordinator.
    func beginCancellation(runID: UUID) -> Bool {
        guard self.runID == runID, phase == .running else { return false }
        diagnosticsRecorder.record(
            category: .ui,
            event: "agent_presentation.cancellation_started",
            fields: ["run_id": runID.uuidString])
        flushPendingPublication()
        phase = .cancelling
        publishNow()
        return true
    }

    /// Marks the full conversation terminal and settles any remaining work details.
    func complete(runID: UUID, result: AgentRunResult) {
        guard self.runID == runID, phase?.isTerminal == false else { return }
        diagnosticsRecorder.record(
            category: .ui,
            event: "agent_presentation.completed",
            fields: [
                "run_id": runID.uuidString,
                "stop_reason": result.stopReason.rawValue,
            ])
        flushPendingPublication()
        settleTools()
        phase = .completed(result.stopReason)
        permissions = []
        stopRuntimeTimers()
        publishNow()
    }

    /// Marks the full conversation failed while preserving already streamed output.
    func fail(runID: UUID, message: String) {
        guard self.runID == runID, phase?.isTerminal == false else { return }
        diagnosticsRecorder.record(
            category: .ui,
            event: "agent_presentation.failed",
            level: .error,
            fields: [
                "run_id": runID.uuidString,
                "error_character_count": String(message.count),
            ])
        flushPendingPublication()
        settleTools()
        phase = .failed(message)
        permissions = []
        stopRuntimeTimers()
        publishNow()
    }

    /// Removes terminal retained state for a matching run.
    func close(runID: UUID) {
        guard self.runID == runID else { return }
        stopRuntimeTimers()
    }

    func discard(runID: UUID) {
        guard self.runID == runID else { return }
        clearRetainedRun()
    }

    /// Cancels publication timers and drops all retained conversation data.
    func shutdown() {
        clearRetainedRun()
    }

    func clearRetainedRun() {
        let clearedRunID = runID
        cancelTimers()
        runID = nil
        profileID = nil
        accent = nil
        prompt = nil
        providerName = nil
        phase = nil
        voiceInput = ""
        needsResponseSeparator = false
        outputBuffer.removeAll(keepingCapacity: false)
        diagnosticBuffer.removeAll(keepingCapacity: false)
        plan.removeAll(keepingCapacity: false)
        tools.removeAll(keepingCapacity: false)
        timeline.removeAll(keepingCapacity: false)
        timelineHasOmittedActivity = false
        permissions.removeAll(keepingCapacity: false)
        notices.removeAll(keepingCapacity: false)
        elapsedSeconds = 0
        evictedToolCount = 0
        ignoredToolUpdateCount = 0
        diagnosticsRecorder.record(
            category: .ui,
            event: "agent_presentation.cleared",
            fields: ["run_id": clearedRunID?.uuidString ?? ""])
    }

}

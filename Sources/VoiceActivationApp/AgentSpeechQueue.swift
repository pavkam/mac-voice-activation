// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import VoiceActivationCore

enum AgentSpeechQueueState: Equatable {
    case idle
    case preparing
    case starting
    case playing
}

struct AgentSpeechConfiguration: Equatable, Sendable {
    let provider: AgentSpeechProvider
    let elevenLabsAPIKey: String
    let elevenLabsVoiceID: String

    static let systemDefault = AgentSpeechConfiguration(
        provider: .system,
        elevenLabsAPIKey: "",
        elevenLabsVoiceID: "")
}

struct AgentSpeechRequest: Equatable, Sendable {
    let text: String
    let localeID: String
    let configuration: AgentSpeechConfiguration
}

@MainActor
protocol AgentSpeechQueueing: AnyObject {
    var onStateChange: ((AgentSpeechQueueState) -> Void)? { get set }

    func enqueue(_ request: AgentSpeechRequest)
    func stop()
}

@MainActor
final class AgentSpeechQueue: AgentSpeechQueueing {
    private static let maximumPendingRequests = 64
    private static let maximumConcurrentSynthesisRequests = 2
    private static let maximumCoalescedCharacters = 20_000

    var onStateChange: ((AgentSpeechQueueState) -> Void)?

    private enum Preparation {
        case cloud(Data)
        case system
    }

    private struct PreparedCloudAudio: Sendable {
        let data: Data
        let readyAtUptime: UInt64
    }

    private struct PendingRequest {
        let id: UInt64
        var request: AgentSpeechRequest
        let enqueuedAtUptime: UInt64
        var synthesis: Task<PreparedCloudAudio, any Error>?
        var preparation: Preparation?
    }

    private let synthesizer: any ElevenLabsSpeechSynthesizing
    private let audioPlayer: any AgentAudioDataPlaying
    private let systemSpeechPlayer: any AgentSystemSpeechPlaying
    private let diagnostics: any VoiceActivationDiagnosticRecording
    private var pending: [PendingRequest] = []
    private var activePlaybackID: UInt64?
    private var state = AgentSpeechQueueState.idle
    private var generation: UInt64 = 0
    private var nextID: UInt64 = 0

    init(
        synthesizer: any ElevenLabsSpeechSynthesizing = ElevenLabsSpeechClient(),
        audioPlayer: any AgentAudioDataPlaying = SystemAgentAudioDataPlayer(),
        systemSpeechPlayer: any AgentSystemSpeechPlaying = SystemAgentSpeechPlayer(),
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.synthesizer = synthesizer
        self.audioPlayer = audioPlayer
        self.systemSpeechPlayer = systemSpeechPlayer
        self.diagnostics = diagnostics
    }

    func enqueue(_ request: AgentSpeechRequest) {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            diagnostics.record(
                category: .audio,
                event: "speech.queue_rejected",
                level: .warning,
                fields: ["reason": "empty"])
            return
        }
        let boundedRequest = AgentSpeechRequest(
            text: String(text.prefix(Self.maximumCoalescedCharacters)),
            localeID: request.localeID,
            configuration: request.configuration)
        let appended = append(boundedRequest)
        diagnostics.record(
            category: .audio,
            event: "speech.queue_enqueued",
            fields: [
                "request_id": String(appended.id),
                "provider": boundedRequest.configuration.provider.rawValue,
                "character_count": String(boundedRequest.text.count),
                "pending_count": String(pending.count),
                "coalesced": String(appended.coalesced),
                "generation": String(generation),
            ])
        startPrefetching()
        advance()
    }

    func stop() {
        let stoppedGeneration = generation
        let cancelledCount = pending.count
        let stoppedPlayback = activePlaybackID != nil
        generation &+= 1
        for request in pending {
            request.synthesis?.cancel()
        }
        pending.removeAll(keepingCapacity: true)
        activePlaybackID = nil
        audioPlayer.stop()
        systemSpeechPlayer.stop()
        setState(.idle)
        diagnostics.record(
            category: .audio,
            event: "speech.queue_stopped",
            fields: [
                "previous_generation": String(stoppedGeneration),
                "generation": String(generation),
                "cancelled_request_count": String(cancelledCount),
                "stopped_playback": String(stoppedPlayback),
            ])
    }

    private func append(_ request: AgentSpeechRequest) -> (id: UInt64, coalesced: Bool) {
        guard pending.count >= Self.maximumPendingRequests,
            var previous = pending.popLast()
        else {
            let pendingRequest = makePendingRequest(request)
            pending.append(pendingRequest)
            return (pendingRequest.id, false)
        }

        previous.synthesis?.cancel()
        let combinedText = String(
            "\(previous.request.text) \(request.text)"
                .suffix(Self.maximumCoalescedCharacters))
        previous = makePendingRequest(
            AgentSpeechRequest(
                text: combinedText,
                localeID: request.localeID,
                configuration: request.configuration))
        pending.append(previous)
        return (previous.id, true)
    }

    private func makePendingRequest(_ request: AgentSpeechRequest) -> PendingRequest {
        nextID &+= 1
        let preparation: Preparation? =
            request.configuration.provider == .system
            ? .system
            : nil
        return PendingRequest(
            id: nextID,
            request: request,
            enqueuedAtUptime: DispatchTime.now().uptimeNanoseconds,
            synthesis: nil,
            preparation: preparation)
    }

    private func startPrefetching() {
        var availableSlots =
            Self.maximumConcurrentSynthesisRequests
            - pending.reduce(into: 0) { count, request in
                if request.synthesis != nil {
                    count += 1
                }
            }
        guard availableSlots > 0 else { return }

        for index in pending.indices
        where pending[index].preparation == nil && pending[index].synthesis == nil {
            let pendingRequest = pending[index]
            let configuration = pendingRequest.request.configuration
            guard configuration.provider == .elevenLabs,
                !configuration.elevenLabsAPIKey.isEmpty,
                !configuration.elevenLabsVoiceID.isEmpty
            else {
                pending[index].preparation = .system
                diagnostics.record(
                    category: .audio,
                    event: "speech.synthesis_bypassed",
                    fields: [
                        "request_id": String(pendingRequest.id),
                        "reason": configuration.provider == .system
                            ? "system_provider"
                            : "incomplete_cloud_configuration",
                    ])
                continue
            }

            let request = pendingRequest.request
            let synthesizer = synthesizer
            let diagnostics = diagnostics
            let requestID = pendingRequest.id
            let enqueuedAtUptime = pendingRequest.enqueuedAtUptime
            let synthesis = Task.detached(priority: .userInitiated) {
                let startedAtUptime = DispatchTime.now().uptimeNanoseconds
                diagnostics.record(
                    category: .audio,
                    event: "speech.synthesis_started",
                    fields: [
                        "request_id": String(requestID),
                        "provider": configuration.provider.rawValue,
                        "character_count": String(request.text.count),
                        "queue_wait_ms": String(
                            Self.milliseconds(
                                from: enqueuedAtUptime,
                                to: startedAtUptime)),
                        "task_priority": String(Task.currentPriority.rawValue),
                    ])
                do {
                    let data = try await synthesizer.audio(
                        text: request.text,
                        apiKey: configuration.elevenLabsAPIKey,
                        voiceID: configuration.elevenLabsVoiceID)
                    let readyAtUptime = DispatchTime.now().uptimeNanoseconds
                    diagnostics.record(
                        category: .audio,
                        event: "speech.synthesis_finished",
                        fields: [
                            "request_id": String(requestID),
                            "outcome": "success",
                            "duration_ms": String(
                                Self.milliseconds(
                                    from: startedAtUptime,
                                    to: readyAtUptime)),
                            "audio_byte_count": String(data.count),
                            "task_priority": String(Task.currentPriority.rawValue),
                        ])
                    return PreparedCloudAudio(data: data, readyAtUptime: readyAtUptime)
                } catch {
                    let failedAtUptime = DispatchTime.now().uptimeNanoseconds
                    diagnostics.record(
                        category: .audio,
                        event: "speech.synthesis_finished",
                        level: .error,
                        fields: [
                            "request_id": String(requestID),
                            "outcome": error is CancellationError ? "cancelled" : "failure",
                            "duration_ms": String(
                                Self.milliseconds(
                                    from: startedAtUptime,
                                    to: failedAtUptime)),
                            "error_type": String(describing: type(of: error)),
                            "task_priority": String(Task.currentPriority.rawValue),
                        ])
                    throw error
                }
            }
            pending[index].synthesis = synthesis
            let activeGeneration = generation
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = await synthesis.result
                await MainRunLoopScheduler.shared.perform { [weak self] in
                    self?.completeSynthesis(
                        requestID: requestID,
                        generation: activeGeneration,
                        result: result)
                }
            }
            availableSlots -= 1
            if availableSlots == 0 {
                break
            }
        }
    }

    private func completeSynthesis(
        requestID: UInt64,
        generation activeGeneration: UInt64,
        result: Result<PreparedCloudAudio, any Error>
    ) {
        guard generation == activeGeneration,
            let index = pending.firstIndex(where: { $0.id == requestID })
        else {
            diagnostics.record(
                category: .audio,
                event: "speech.synthesis_result_discarded",
                fields: [
                    "request_id": String(requestID),
                    "result_generation": String(activeGeneration),
                    "generation": String(generation),
                ])
            return
        }
        pending[index].synthesis = nil
        switch result {
        case .success(let preparedAudio) where !preparedAudio.data.isEmpty:
            let receivedAtUptime = DispatchTime.now().uptimeNanoseconds
            pending[index].preparation = .cloud(preparedAudio.data)
            diagnostics.record(
                category: .audio,
                event: "speech.synthesis_result_received",
                fields: [
                    "request_id": String(requestID),
                    "main_delivery_ms": String(
                        Self.milliseconds(
                            from: preparedAudio.readyAtUptime,
                            to: receivedAtUptime)),
                    "audio_byte_count": String(preparedAudio.data.count),
                    "task_priority": String(Task.currentPriority.rawValue),
                    "run_loop_mode": RunLoop.current.currentMode?.rawValue ?? "none",
                ])
        case .success, .failure:
            pending[index].preparation = .system
            diagnostics.record(
                category: .audio,
                event: "speech.synthesis_fallback_selected",
                level: .warning,
                fields: ["request_id": String(requestID)])
        }
        startPrefetching()
        advance()
    }

    private func advance(continuingSpeech: Bool = false) {
        guard activePlaybackID == nil else { return }
        guard let first = pending.first else {
            setState(.idle)
            return
        }
        guard let preparation = first.preparation else {
            setState(.preparing)
            return
        }

        pending.removeFirst()
        startPrefetching()
        switch preparation {
        case .cloud(let data):
            startCloudPlayback(
                data,
                request: first.request,
                requestID: first.id,
                continuingSpeech: continuingSpeech)
        case .system:
            startSystemPlayback(
                request: first.request,
                requestID: first.id,
                continuingSpeech: continuingSpeech)
        }
    }

    private func startCloudPlayback(
        _ data: Data,
        request: AgentSpeechRequest,
        requestID: UInt64,
        continuingSpeech: Bool
    ) {
        diagnostics.record(
            category: .audio,
            event: "speech.playback_starting",
            fields: [
                "request_id": String(requestID),
                "kind": "cloud",
                "audio_byte_count": String(data.count),
            ])
        if !continuingSpeech {
            setState(.starting)
        }
        activePlaybackID = requestID
        let activeGeneration = generation
        let started = audioPlayer.play(data) { [weak self] completed in
            self?.completePlayback(
                requestID: requestID,
                generation: activeGeneration,
                completed: completed)
        }
        guard started else {
            diagnostics.record(
                category: .audio,
                event: "speech.playback_rejected",
                level: .warning,
                fields: [
                    "request_id": String(requestID),
                    "kind": "cloud",
                ])
            activePlaybackID = nil
            startSystemPlayback(
                request: request,
                requestID: requestID,
                continuingSpeech: continuingSpeech)
            return
        }
        guard activePlaybackID == requestID, generation == activeGeneration else { return }
        diagnostics.record(
            category: .audio,
            event: "speech.playback_started",
            fields: [
                "request_id": String(requestID),
                "kind": "cloud",
            ])
        setState(.playing)
    }

    private func startSystemPlayback(
        request: AgentSpeechRequest,
        requestID: UInt64,
        continuingSpeech: Bool
    ) {
        diagnostics.record(
            category: .audio,
            event: "speech.playback_starting",
            fields: [
                "request_id": String(requestID),
                "kind": "system",
                "character_count": String(request.text.count),
            ])
        if !continuingSpeech {
            setState(.starting)
        }
        activePlaybackID = requestID
        let activeGeneration = generation
        let started = systemSpeechPlayer.play(
            text: request.text,
            localeID: request.localeID
        ) { [weak self] in
            self?.completePlayback(
                requestID: requestID,
                generation: activeGeneration,
                completed: true)
        }
        guard started else {
            diagnostics.record(
                category: .audio,
                event: "speech.playback_rejected",
                level: .error,
                fields: [
                    "request_id": String(requestID),
                    "kind": "system",
                ])
            activePlaybackID = nil
            advance(continuingSpeech: continuingSpeech)
            return
        }
        guard activePlaybackID == requestID, generation == activeGeneration else { return }
        diagnostics.record(
            category: .audio,
            event: "speech.playback_started",
            fields: [
                "request_id": String(requestID),
                "kind": "system",
            ])
        setState(.playing)
    }

    private func completePlayback(
        requestID: UInt64,
        generation activeGeneration: UInt64,
        completed: Bool
    ) {
        guard generation == activeGeneration, activePlaybackID == requestID else { return }
        activePlaybackID = nil
        diagnostics.record(
            category: .audio,
            event: "speech.playback_finished",
            fields: [
                "request_id": String(requestID),
                "completed": String(completed),
                "pending_count": String(pending.count),
            ])
        advance(continuingSpeech: true)
    }

    private func setState(_ state: AgentSpeechQueueState) {
        guard self.state != state else { return }
        self.state = state
        diagnostics.record(
            category: .audio,
            event: "speech.state_changed",
            fields: ["state": String(describing: state)])
        onStateChange?(state)
    }

    nonisolated private static func milliseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        guard end >= start else { return 0 }
        return (end - start) / 1_000_000
    }
}

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

    private struct PendingRequest {
        let id: UInt64
        var request: AgentSpeechRequest
        var synthesis: Task<Data, any Error>?
        var preparation: Preparation?
    }

    private let synthesizer: any ElevenLabsSpeechSynthesizing
    private let audioPlayer: any AgentAudioDataPlaying
    private let systemSpeechPlayer: any AgentSystemSpeechPlaying
    private var pending: [PendingRequest] = []
    private var activePlaybackID: UInt64?
    private var state = AgentSpeechQueueState.idle
    private var generation: UInt64 = 0
    private var nextID: UInt64 = 0

    init(
        synthesizer: any ElevenLabsSpeechSynthesizing = ElevenLabsSpeechClient(),
        audioPlayer: any AgentAudioDataPlaying = SystemAgentAudioDataPlayer(),
        systemSpeechPlayer: any AgentSystemSpeechPlaying = SystemAgentSpeechPlayer())
    {
        self.synthesizer = synthesizer
        self.audioPlayer = audioPlayer
        self.systemSpeechPlayer = systemSpeechPlayer
    }

    func enqueue(_ request: AgentSpeechRequest) {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let boundedRequest = AgentSpeechRequest(
            text: String(text.prefix(Self.maximumCoalescedCharacters)),
            localeID: request.localeID,
            configuration: request.configuration)
        append(boundedRequest)
        startPrefetching()
        advance()
    }

    func stop() {
        generation &+= 1
        for request in pending {
            request.synthesis?.cancel()
        }
        pending.removeAll(keepingCapacity: true)
        activePlaybackID = nil
        audioPlayer.stop()
        systemSpeechPlayer.stop()
        setState(.idle)
    }

    private func append(_ request: AgentSpeechRequest) {
        guard pending.count >= Self.maximumPendingRequests,
              var previous = pending.popLast()
        else {
            pending.append(makePendingRequest(request))
            return
        }

        previous.synthesis?.cancel()
        let combinedText = String(
            "\(previous.request.text) \(request.text)"
                .suffix(Self.maximumCoalescedCharacters))
        previous = makePendingRequest(AgentSpeechRequest(
            text: combinedText,
            localeID: request.localeID,
            configuration: request.configuration))
        pending.append(previous)
    }

    private func makePendingRequest(_ request: AgentSpeechRequest) -> PendingRequest {
        nextID &+= 1
        let preparation: Preparation? = request.configuration.provider == .system
            ? .system
            : nil
        return PendingRequest(
            id: nextID,
            request: request,
            synthesis: nil,
            preparation: preparation)
    }

    private func startPrefetching() {
        var availableSlots = Self.maximumConcurrentSynthesisRequests
            - pending.reduce(into: 0) { count, request in
                if request.synthesis != nil {
                    count += 1
                }
            }
        guard availableSlots > 0 else { return }

        for index in pending.indices
        where pending[index].preparation == nil && pending[index].synthesis == nil
        {
            let pendingRequest = pending[index]
            let configuration = pendingRequest.request.configuration
            guard configuration.provider == .elevenLabs,
                  !configuration.elevenLabsAPIKey.isEmpty,
                  !configuration.elevenLabsVoiceID.isEmpty
            else {
                pending[index].preparation = .system
                continue
            }

            let request = pendingRequest.request
            let synthesizer = synthesizer
            let synthesis = Task.detached(priority: .userInitiated) {
                try await synthesizer.audio(
                    text: request.text,
                    apiKey: configuration.elevenLabsAPIKey,
                    voiceID: configuration.elevenLabsVoiceID)
            }
            pending[index].synthesis = synthesis
            let activeGeneration = generation
            Task { @MainActor [weak self] in
                let result = await synthesis.result
                self?.completeSynthesis(
                    requestID: pendingRequest.id,
                    generation: activeGeneration,
                    result: result)
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
        result: Result<Data, any Error>)
    {
        guard generation == activeGeneration,
              let index = pending.firstIndex(where: { $0.id == requestID })
        else { return }
        pending[index].synthesis = nil
        switch result {
        case let .success(data) where !data.isEmpty:
            pending[index].preparation = .cloud(data)
        case .success, .failure:
            pending[index].preparation = .system
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
        case let .cloud(data):
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
        continuingSpeech: Bool)
    {
        if !continuingSpeech {
            setState(.starting)
        }
        activePlaybackID = requestID
        let activeGeneration = generation
        let started = audioPlayer.play(data) { [weak self] _ in
            self?.completePlayback(requestID: requestID, generation: activeGeneration)
        }
        guard started else {
            activePlaybackID = nil
            startSystemPlayback(
                request: request,
                requestID: requestID,
                continuingSpeech: continuingSpeech)
            return
        }
        guard activePlaybackID == requestID, generation == activeGeneration else { return }
        setState(.playing)
    }

    private func startSystemPlayback(
        request: AgentSpeechRequest,
        requestID: UInt64,
        continuingSpeech: Bool)
    {
        if !continuingSpeech {
            setState(.starting)
        }
        activePlaybackID = requestID
        let activeGeneration = generation
        let started = systemSpeechPlayer.play(
            text: request.text,
            localeID: request.localeID)
        { [weak self] in
            self?.completePlayback(requestID: requestID, generation: activeGeneration)
        }
        guard started else {
            activePlaybackID = nil
            advance(continuingSpeech: continuingSpeech)
            return
        }
        guard activePlaybackID == requestID, generation == activeGeneration else { return }
        setState(.playing)
    }

    private func completePlayback(requestID: UInt64, generation activeGeneration: UInt64) {
        guard generation == activeGeneration, activePlaybackID == requestID else { return }
        activePlaybackID = nil
        advance(continuingSpeech: true)
    }

    private func setState(_ state: AgentSpeechQueueState) {
        guard self.state != state else { return }
        self.state = state
        onStateChange?(state)
    }
}

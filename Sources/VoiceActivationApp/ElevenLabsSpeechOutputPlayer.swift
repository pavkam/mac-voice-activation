// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import Foundation

@MainActor
protocol AgentAudioDataPlaying: AnyObject {
    var isPlaying: Bool { get }

    @discardableResult
    func play(_ data: Data) -> Bool
    func stop()
}

@MainActor
final class SystemAgentAudioDataPlayer: AgentAudioDataPlaying {
    private var sound: NSSound?

    var isPlaying: Bool {
        sound?.isPlaying ?? false
    }

    @discardableResult
    func play(_ data: Data) -> Bool {
        guard let sound = NSSound(data: data) else { return false }
        self.sound = sound
        return sound.play()
    }

    func stop() {
        sound?.stop()
        sound = nil
    }
}

@MainActor
final class ElevenLabsSpeechOutputPlayer {
    private static let maximumPendingRequests = 64
    private static let maximumConcurrentSynthesisRequests = 2
    private static let maximumCoalescedCharacters = 20_000

    var onSpeakingChange: ((Bool) -> Void)?
    var onFailure: ((String, String) -> Void)?

    private struct Request {
        let text: String
        let apiKey: String
        let voiceID: String
        let localeID: String
    }

    private struct PendingRequest {
        let request: Request
        var synthesis: Task<Data, any Error>?
    }

    private let synthesizer: any ElevenLabsSpeechSynthesizing
    private let audioPlayer: any AgentAudioDataPlaying
    private let playbackLeadTime: Duration
    private var pending: [PendingRequest] = []
    private var activeSynthesis: Task<Data, any Error>?
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var isSpeaking = false

    init(
        synthesizer: any ElevenLabsSpeechSynthesizing = ElevenLabsSpeechClient(),
        audioPlayer: any AgentAudioDataPlaying = SystemAgentAudioDataPlayer(),
        playbackLeadTime: Duration = .milliseconds(80))
    {
        self.synthesizer = synthesizer
        self.audioPlayer = audioPlayer
        self.playbackLeadTime = playbackLeadTime
    }

    func speak(
        _ text: String,
        apiKey: String,
        voiceID: String,
        localeID: String = Locale.current.identifier)
    {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        enqueue(Request(
            text: text,
            apiKey: apiKey,
            voiceID: voiceID,
            localeID: localeID))
        startWorkerIfNeeded()
    }

    func stop() {
        generation += 1
        activeSynthesis?.cancel()
        activeSynthesis = nil
        for request in pending {
            request.synthesis?.cancel()
        }
        pending.removeAll(keepingCapacity: true)
        worker?.cancel()
        worker = nil
        audioPlayer.stop()
        setSpeaking(false)
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        let activeGeneration = generation
        worker = Task { @MainActor [weak self] in
            await self?.drainQueue(generation: activeGeneration)
        }
    }

    private func drainQueue(generation activeGeneration: Int) async {
        while !Task.isCancelled,
              generation == activeGeneration,
              !pending.isEmpty
        {
            startPrefetching()
            let pendingRequest = pending.removeFirst()
            let request = pendingRequest.request
            do {
                guard let synthesis = pendingRequest.synthesis else {
                    preconditionFailure("The next speech request must be prefetched.")
                }
                activeSynthesis = synthesis
                startPrefetching()
                let data = try await synthesis.value
                activeSynthesis = nil
                startPrefetching()
                try Task.checkCancellation()
                guard generation == activeGeneration else { return }
                let isStartingSpeech = !isSpeaking
                setSpeaking(true)
                if isStartingSpeech {
                    // Give the working effect and recognition pipeline time to release
                    // their audio buffers before the first spoken sample is submitted.
                    try await Task.sleep(for: playbackLeadTime)
                }
                try Task.checkCancellation()
                guard generation == activeGeneration else { return }
                guard audioPlayer.play(data) else {
                    fallBackRemainingQueue(startingWith: request)
                    break
                }

                while audioPlayer.isPlaying {
                    try await Task.sleep(for: .milliseconds(50))
                }
                if pending.isEmpty {
                    setSpeaking(false)
                }
            } catch is CancellationError {
                activeSynthesis = nil
                return
            } catch {
                activeSynthesis = nil
                guard !Task.isCancelled, generation == activeGeneration else { return }
                fallBackRemainingQueue(startingWith: request)
                break
            }
        }

        guard generation == activeGeneration, !Task.isCancelled else { return }
        worker = nil
        setSpeaking(false)
    }

    private func setSpeaking(_ speaking: Bool) {
        guard speaking != isSpeaking else { return }
        isSpeaking = speaking
        onSpeakingChange?(speaking)
    }

    private func enqueue(_ request: Request) {
        guard pending.count >= Self.maximumPendingRequests,
              let previous = pending.popLast()
        else {
            pending.append(PendingRequest(request: request, synthesis: nil))
            startPrefetching()
            return
        }

        previous.synthesis?.cancel()

        let combinedText = String(
            "\(previous.request.text) \(request.text)".suffix(Self.maximumCoalescedCharacters))
        pending.append(PendingRequest(request: Request(
            text: combinedText,
            apiKey: request.apiKey,
            voiceID: request.voiceID,
            localeID: request.localeID), synthesis: nil))
        startPrefetching()
    }

    private func startPrefetching() {
        let pendingSynthesisCount = pending.reduce(into: 0) { count, request in
            if request.synthesis != nil {
                count += 1
            }
        }
        var availableSlots = Self.maximumConcurrentSynthesisRequests
            - pendingSynthesisCount
            - (activeSynthesis == nil ? 0 : 1)
        guard availableSlots > 0 else { return }

        for index in pending.indices where pending[index].synthesis == nil {
            let request = pending[index].request
            let synthesizer = synthesizer
            pending[index].synthesis = Task {
                try await synthesizer.audio(
                    text: request.text,
                    apiKey: request.apiKey,
                    voiceID: request.voiceID)
            }
            availableSlots -= 1
            if availableSlots == 0 {
                break
            }
        }
    }

    private func fallBackRemainingQueue(startingWith request: Request) {
        var combinedText = request.text
        for pendingRequest in pending {
            combinedText.append(" ")
            combinedText.append(pendingRequest.request.text)
            if combinedText.count > Self.maximumCoalescedCharacters {
                combinedText = String(combinedText.suffix(Self.maximumCoalescedCharacters))
            }
            pendingRequest.synthesis?.cancel()
        }
        pending.removeAll(keepingCapacity: true)
        onFailure?(combinedText, request.localeID)
    }
}

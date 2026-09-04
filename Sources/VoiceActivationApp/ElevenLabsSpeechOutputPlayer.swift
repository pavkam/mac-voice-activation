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
    private static let maximumCoalescedCharacters = 20_000

    var onSpeakingChange: ((Bool) -> Void)?
    var onFailure: ((String, String) -> Void)?

    private struct Request {
        let text: String
        let apiKey: String
        let voiceID: String
        let localeID: String
    }

    private let synthesizer: any ElevenLabsSpeechSynthesizing
    private let audioPlayer: any AgentAudioDataPlaying
    private var pending: [Request] = []
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var isSpeaking = false

    init(
        synthesizer: any ElevenLabsSpeechSynthesizing = ElevenLabsSpeechClient(),
        audioPlayer: any AgentAudioDataPlaying = SystemAgentAudioDataPlayer())
    {
        self.synthesizer = synthesizer
        self.audioPlayer = audioPlayer
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
        setSpeaking(true)
        startWorkerIfNeeded()
    }

    func stop() {
        generation += 1
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
            let request = pending.removeFirst()
            do {
                let data = try await synthesizer.audio(
                    text: request.text,
                    apiKey: request.apiKey,
                    voiceID: request.voiceID)
                try Task.checkCancellation()
                guard generation == activeGeneration else { return }
                guard audioPlayer.play(data) else {
                    fallBackRemainingQueue(startingWith: request)
                    break
                }

                while audioPlayer.isPlaying {
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch is CancellationError {
                return
            } catch {
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
            pending.append(request)
            return
        }

        let combinedText = String(
            "\(previous.text) \(request.text)".suffix(Self.maximumCoalescedCharacters))
        pending.append(Request(
            text: combinedText,
            apiKey: request.apiKey,
            voiceID: request.voiceID,
            localeID: request.localeID))
    }

    private func fallBackRemainingQueue(startingWith request: Request) {
        var combinedText = request.text
        for pendingRequest in pending {
            combinedText.append(" ")
            combinedText.append(pendingRequest.text)
            if combinedText.count > Self.maximumCoalescedCharacters {
                combinedText = String(combinedText.suffix(Self.maximumCoalescedCharacters))
            }
        }
        pending.removeAll(keepingCapacity: true)
        onFailure?(combinedText, request.localeID)
    }
}

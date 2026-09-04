// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AVFoundation
import AppKit
import Foundation
import VoiceActivationCore

@MainActor
protocol AgentAudioDataPlaying: AnyObject {
    @discardableResult
    func play(
        _ data: Data,
        completion: @escaping @MainActor (Bool) -> Void
    ) -> Bool
    func stop()
}

@MainActor
final class SystemAgentAudioDataPlayer: NSObject, AgentAudioDataPlaying, NSSoundDelegate {
    private var sound: NSSound?
    private var completion: (@MainActor (Bool) -> Void)?
    private let diagnostics: any VoiceActivationDiagnosticRecording

    init(
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.diagnostics = diagnostics
        super.init()
    }

    @discardableResult
    func play(
        _ data: Data,
        completion: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        stop()
        guard let sound = NSSound(data: data) else {
            diagnostics.record(
                category: .audio,
                event: "cloud_playback.decode_failed",
                level: .error,
                fields: ["audio_byte_count": String(data.count)])
            return false
        }
        sound.delegate = self
        self.sound = sound
        self.completion = completion
        guard sound.play() else {
            diagnostics.record(
                category: .audio,
                event: "cloud_playback.start_failed",
                level: .error,
                fields: ["audio_byte_count": String(data.count)])
            clearPlayback()
            return false
        }
        diagnostics.record(
            category: .audio,
            event: "cloud_playback.started",
            fields: ["audio_byte_count": String(data.count)])
        return true
    }

    func stop() {
        let hadPlayback = sound != nil
        sound?.delegate = nil
        sound?.stop()
        clearPlayback()
        diagnostics.record(
            category: .audio,
            event: "cloud_playback.stopped",
            fields: ["had_playback": String(hadPlayback)])
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        guard sound === self.sound else { return }
        let completion = completion
        clearPlayback()
        diagnostics.record(
            category: .audio,
            event: "cloud_playback.finished",
            fields: ["completed": String(flag)])
        completion?(flag)
    }

    private func clearPlayback() {
        sound?.delegate = nil
        sound = nil
        completion = nil
    }
}

@MainActor
protocol AgentSystemSpeechPlaying: AnyObject {
    @discardableResult
    func play(
        text: String,
        localeID: String,
        completion: @escaping @MainActor () -> Void
    ) -> Bool
    func stop()
}

@MainActor
final class SystemAgentSpeechPlayer: NSObject, AgentSystemSpeechPlaying,
    @preconcurrency AVSpeechSynthesizerDelegate
{
    private let synthesizer: AVSpeechSynthesizer
    private let diagnostics: any VoiceActivationDiagnosticRecording
    private var utterance: AVSpeechUtterance?
    private var completion: (@MainActor () -> Void)?

    init(
        synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer(),
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.synthesizer = synthesizer
        self.diagnostics = diagnostics
        super.init()
        synthesizer.delegate = self
    }

    @discardableResult
    func play(
        text: String,
        localeID: String,
        completion: @escaping @MainActor () -> Void
    ) -> Bool {
        if utterance != nil {
            stop()
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: localeID)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94
        utterance.pitchMultiplier = 1.02
        self.utterance = utterance
        self.completion = completion
        synthesizer.speak(utterance)
        diagnostics.record(
            category: .audio,
            event: "system_speech.started",
            fields: ["character_count": String(text.count)])
        return true
    }

    func stop() {
        let hadActiveUtterance = utterance != nil
        utterance = nil
        completion = nil
        if hadActiveUtterance, synthesizer.isSpeaking {
            _ = synthesizer.stopSpeaking(at: .immediate)
        }
        diagnostics.record(
            category: .audio,
            event: "system_speech.stopped",
            fields: ["had_active_utterance": String(hadActiveUtterance)])
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        finish(utterance)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        finish(utterance)
    }

    private func finish(_ utterance: AVSpeechUtterance) {
        guard utterance === self.utterance else { return }
        let completion = completion
        self.utterance = nil
        self.completion = nil
        diagnostics.record(category: .audio, event: "system_speech.finished")
        completion?()
    }
}

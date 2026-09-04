// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import AVFoundation
import Foundation

@MainActor
protocol AgentAudioDataPlaying: AnyObject {
    @discardableResult
    func play(
        _ data: Data,
        completion: @escaping @MainActor (Bool) -> Void) -> Bool
    func stop()
}

@MainActor
final class SystemAgentAudioDataPlayer: NSObject, AgentAudioDataPlaying, NSSoundDelegate {
    private var sound: NSSound?
    private var completion: (@MainActor (Bool) -> Void)?

    @discardableResult
    func play(
        _ data: Data,
        completion: @escaping @MainActor (Bool) -> Void) -> Bool
    {
        stop()
        guard let sound = NSSound(data: data) else { return false }
        sound.delegate = self
        self.sound = sound
        self.completion = completion
        guard sound.play() else {
            clearPlayback()
            return false
        }
        return true
    }

    func stop() {
        sound?.delegate = nil
        sound?.stop()
        clearPlayback()
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        guard sound === self.sound else { return }
        let completion = completion
        clearPlayback()
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
        completion: @escaping @MainActor () -> Void) -> Bool
    func stop()
}

@MainActor
final class SystemAgentSpeechPlayer: NSObject, AgentSystemSpeechPlaying,
    @preconcurrency AVSpeechSynthesizerDelegate
{
    private let synthesizer: AVSpeechSynthesizer
    private var utterance: AVSpeechUtterance?
    private var completion: (@MainActor () -> Void)?

    init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        super.init()
        synthesizer.delegate = self
    }

    @discardableResult
    func play(
        text: String,
        localeID: String,
        completion: @escaping @MainActor () -> Void) -> Bool
    {
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
        return true
    }

    func stop() {
        let hadActiveUtterance = utterance != nil
        utterance = nil
        completion = nil
        if hadActiveUtterance, synthesizer.isSpeaking {
            _ = synthesizer.stopSpeaking(at: .immediate)
        }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance)
    {
        finish(utterance)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance)
    {
        finish(utterance)
    }

    private func finish(_ utterance: AVSpeechUtterance) {
        guard utterance === self.utterance else { return }
        let completion = completion
        self.utterance = nil
        self.completion = nil
        completion?()
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationApp
@testable import VoiceActivationCore

@MainActor
final class AgentConversationAudioSpy: AgentConversationAudioPlaying {
    enum Event: Equatable {
        case activity(AgentActivitySound)
        case speech(String)
    }

    var onSpeakingChange: ((Bool) -> Void)?
    var onSpeak: (() -> Void)?
    private(set) var workingStates: [Bool] = []
    private(set) var activitySounds: [AgentActivitySound] = []
    private(set) var spoken: [(text: String, localeID: String)] = []
    private(set) var events: [Event] = []
    private(set) var stopSpeakingCount = 0
    private(set) var stopAllCount = 0

    func setWorking(_ working: Bool) {
        workingStates.append(working)
    }

    func playActivitySound(_ sound: AgentActivitySound) {
        activitySounds.append(sound)
        events.append(.activity(sound))
    }

    func speak(_ text: String, localeID: String) {
        spoken.append((text, localeID))
        events.append(.speech(text))
        onSpeak?()
    }

    func stopSpeaking() {
        stopSpeakingCount += 1
    }

    func stopAll() {
        stopAllCount += 1
    }
}

@MainActor
final class AgentSpeechQueueSpy: AgentSpeechQueueing {
    var onStateChange: ((AgentSpeechQueueState) -> Void)?
    private(set) var requests: [AgentSpeechRequest] = []
    private(set) var stopCount = 0

    func enqueue(_ request: AgentSpeechRequest) {
        requests.append(request)
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ state: AgentSpeechQueueState) {
        onStateChange?(state)
    }
}

@MainActor
final class AgentActivitySoundLoopSpy: AgentActivitySoundLooping {
    private(set) var workingStates: [Bool] = []
    private(set) var suppressionStates: [Bool] = []
    private(set) var sounds: [AgentActivitySound] = []
    private(set) var stopCount = 0
    var onSuppression: ((Bool) -> Void)?

    func setWorking(_ working: Bool) {
        workingStates.append(working)
    }

    func setSpeechSuppressed(_ suppressed: Bool) {
        suppressionStates.append(suppressed)
        onSuppression?(suppressed)
    }

    func play(_ sound: AgentActivitySound) {
        sounds.append(sound)
    }

    func stop() {
        stopCount += 1
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AgentConversationAudioPresenterTests {
}

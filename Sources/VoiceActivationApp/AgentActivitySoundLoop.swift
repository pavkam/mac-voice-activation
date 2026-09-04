// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import VoiceActivationCore

@MainActor
protocol AgentActivitySoundLooping: AnyObject {
    func setWorking(_ working: Bool)
    func setSpeechSuppressed(_ suppressed: Bool)
    func play(_ sound: AgentActivitySound)
    func stop()
}

@MainActor
final class AgentActivitySoundLoop: AgentActivitySoundLooping {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let player: any AgentActivitySoundPlaying
    private let initialDelay: Duration
    private let interval: Duration
    private let sleep: Sleep
    private let diagnostics: any VoiceActivationDiagnosticRecording
    private var pulseTask: Task<Void, Never>?
    private var working = false
    private var speechSuppressed = false

    init(
        player: any AgentActivitySoundPlaying,
        initialDelay: Duration = .seconds(1.6),
        interval: Duration = .seconds(3.2),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.player = player
        self.initialDelay = initialDelay
        self.interval = interval
        self.sleep = sleep
        self.diagnostics = diagnostics
    }

    func setWorking(_ working: Bool) {
        guard self.working != working else { return }
        self.working = working
        diagnostics.record(
            category: .audio,
            event: "activity.working_changed",
            fields: [
                "working": String(working),
                "speech_suppressed": String(speechSuppressed),
            ])
        if working {
            start()
        } else {
            silence()
        }
    }

    func setSpeechSuppressed(_ suppressed: Bool) {
        guard speechSuppressed != suppressed else { return }
        speechSuppressed = suppressed
        diagnostics.record(
            category: .audio,
            event: "activity.speech_suppression_changed",
            fields: [
                "suppressed": String(suppressed),
                "working": String(working),
            ])
        if suppressed {
            silence()
        } else if working {
            schedulePulse(after: initialDelay)
        }
    }

    func play(_ sound: AgentActivitySound) {
        guard working, !speechSuppressed else {
            diagnostics.record(
                category: .audio,
                event: "activity.sound_suppressed",
                fields: [
                    "sound": sound.diagnosticName,
                    "working": String(working),
                    "speech_suppressed": String(speechSuppressed),
                ])
            return
        }
        pulseTask?.cancel()
        pulseTask = nil
        diagnostics.record(
            category: .audio,
            event: "activity.sound_requested",
            fields: ["sound": sound.diagnosticName])
        player.play(sound)
        schedulePulse(after: initialDelay)
    }

    func stop() {
        let wasWorking = working
        let wasSuppressed = speechSuppressed
        working = false
        speechSuppressed = false
        silence()
        diagnostics.record(
            category: .audio,
            event: "activity.stopped",
            fields: [
                "was_working": String(wasWorking),
                "was_speech_suppressed": String(wasSuppressed),
            ])
    }

    private func start() {
        silence()
        guard working, !speechSuppressed else { return }
        diagnostics.record(
            category: .audio,
            event: "activity.sound_requested",
            fields: ["sound": AgentActivitySound.thinking.diagnosticName])
        player.play(.thinking)
        schedulePulse(after: interval)
    }

    private func silence() {
        let cancelledPulse = pulseTask != nil
        pulseTask?.cancel()
        pulseTask = nil
        player.stop()
        diagnostics.record(
            category: .audio,
            event: "activity.silenced",
            fields: ["cancelled_scheduled_pulse": String(cancelledPulse)])
    }

    private func schedulePulse(after delay: Duration) {
        guard working, !speechSuppressed else { return }
        let sleep = sleep
        diagnostics.record(
            category: .audio,
            event: "activity.pulse_scheduled",
            fields: ["delay": String(describing: delay)])
        pulseTask = Task { @MainActor [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self, self.working, !self.speechSuppressed else { return }
            self.diagnostics.record(
                category: .audio,
                event: "activity.pulse_fired",
                fields: [:])
            self.player.play(.thinking)
            self.schedulePulse(after: self.interval)
        }
    }
}

extension AgentActivitySound {
    fileprivate var diagnosticName: String {
        switch self {
        case .thinking: "thinking"
        case .toolStarted: "tool_started"
        case .toolCompleted: "tool_completed"
        case .toolFailed: "tool_failed"
        }
    }
}

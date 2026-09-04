// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

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
    private var pulseTask: Task<Void, Never>?
    private var working = false
    private var speechSuppressed = false

    init(
        player: any AgentActivitySoundPlaying,
        initialDelay: Duration = .seconds(1.6),
        interval: Duration = .seconds(3.2),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) })
    {
        self.player = player
        self.initialDelay = initialDelay
        self.interval = interval
        self.sleep = sleep
    }

    func setWorking(_ working: Bool) {
        guard self.working != working else { return }
        self.working = working
        if working {
            start()
        } else {
            silence()
        }
    }

    func setSpeechSuppressed(_ suppressed: Bool) {
        guard speechSuppressed != suppressed else { return }
        speechSuppressed = suppressed
        if suppressed {
            silence()
        } else if working {
            schedulePulse(after: initialDelay)
        }
    }

    func play(_ sound: AgentActivitySound) {
        guard working, !speechSuppressed else { return }
        pulseTask?.cancel()
        pulseTask = nil
        player.play(sound)
        schedulePulse(after: initialDelay)
    }

    func stop() {
        working = false
        speechSuppressed = false
        silence()
    }

    private func start() {
        silence()
        guard working, !speechSuppressed else { return }
        player.play(.thinking)
        schedulePulse(after: interval)
    }

    private func silence() {
        pulseTask?.cancel()
        pulseTask = nil
        player.stop()
    }

    private func schedulePulse(after delay: Duration) {
        guard working, !speechSuppressed else { return }
        let sleep = sleep
        pulseTask = Task { @MainActor [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self, self.working, !self.speechSuppressed else { return }
            self.player.play(.thinking)
            self.schedulePulse(after: self.interval)
        }
    }
}

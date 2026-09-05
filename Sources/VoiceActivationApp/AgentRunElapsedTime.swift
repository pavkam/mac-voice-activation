// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

struct AgentRunElapsedTime: Equatable, Sendable {
    private let startedAt: Date
    private let terminalSeconds: Int?

    init(phase: AgentRunPhase, elapsedSeconds: Int, startedAt: Date) {
        self.startedAt = startedAt
        terminalSeconds = phase.advancesElapsedTime ? nil : max(0, elapsedSeconds)
    }

    func formatted(at date: Date) -> String {
        let seconds = terminalSeconds ?? elapsedSeconds(at: date)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func elapsedSeconds(at date: Date) -> Int {
        let interval = max(0, date.timeIntervalSince(startedAt))
        guard interval < Double(Int.max) else { return Int.max }
        return Int(interval)
    }
}

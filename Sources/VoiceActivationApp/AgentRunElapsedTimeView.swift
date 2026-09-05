// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI
import VoiceActivationCore

/// Displays a live monotonic-looking conversation duration without model timer churn.
struct AgentRunElapsedTimeView: View {
    let phase: AgentRunPhase
    let elapsedSeconds: Int
    let startedAt: Date

    @ViewBuilder
    /// A periodic value while the agent works, frozen while awaiting a follow-up.
    var body: some View {
        let elapsedTime = AgentRunElapsedTime(
            phase: phase,
            elapsedSeconds: elapsedSeconds,
            startedAt: startedAt)
        Group {
            if phase.advancesElapsedTime {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(elapsedTime.formatted(at: context.date))
                }
            } else {
                Text(elapsedTime.formatted(at: startedAt))
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
    }
}

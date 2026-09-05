// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationApp

struct AgentRunElapsedTimeTests {
    @Test func formatted_WhenAgentIsWorking_AdvancesWithoutASnapshotChange() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let elapsedTime = AgentRunElapsedTime(
            phase: .running,
            elapsedSeconds: 0,
            startedAt: startedAt)

        #expect(elapsedTime.formatted(at: startedAt) == "0:00")
        #expect(elapsedTime.formatted(at: startedAt.addingTimeInterval(65)) == "1:05")
    }

    @Test func formatted_WhenAgentIsDoneButConversationListens_FreezesAtPublishedDuration() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let elapsedTime = AgentRunElapsedTime(
            phase: .listening,
            elapsedSeconds: 7,
            startedAt: startedAt)

        #expect(elapsedTime.formatted(at: startedAt) == "0:07")
        #expect(elapsedTime.formatted(at: startedAt.addingTimeInterval(65)) == "0:07")
    }

    @Test func formatted_WhenAgentFinishes_FreezesAtPublishedDuration() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let elapsedTime = AgentRunElapsedTime(
            phase: .completed(.endTurn),
            elapsedSeconds: 62,
            startedAt: startedAt)

        #expect(elapsedTime.formatted(at: startedAt) == "1:02")
        #expect(elapsedTime.formatted(at: startedAt.addingTimeInterval(3_600)) == "1:02")
    }

    @Test func formatted_WhenWallClockMovesBack_DoesNotShowNegativeTime() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let elapsedTime = AgentRunElapsedTime(
            phase: .running,
            elapsedSeconds: 0,
            startedAt: startedAt)

        #expect(elapsedTime.formatted(at: startedAt.addingTimeInterval(-10)) == "0:00")
    }
}

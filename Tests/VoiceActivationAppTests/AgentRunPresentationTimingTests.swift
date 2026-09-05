// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import VoiceActivationApp
@testable import VoiceActivationCore

@Suite(.serialized)
struct AgentRunPresentationTimingTests {
    @MainActor @Test
    func completeTurn_WhenAgentStops_FreezesElapsedSnapshotsWhileConversationListens() async throws {
        let presentation = AgentRunPresentation(elapsedTickInterval: .milliseconds(20))
        let runID = UUID()
        presentation.start(
            runID: runID,
            profile: try makeAgentProfile(),
            prompt: "Time this")
        defer { presentation.shutdown() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(300))
        while presentation.snapshot?.elapsedSeconds == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let activeSeconds = try #require(presentation.snapshot?.elapsedSeconds)
        #expect(activeSeconds > 0)

        presentation.completeTurn(
            runID: runID,
            result: AgentRunResult(stopReason: .endTurn))
        let frozenSeconds = try #require(presentation.snapshot?.elapsedSeconds)
        try await Task.sleep(for: .milliseconds(80))

        #expect(presentation.snapshot?.phase == .listening)
        #expect(presentation.snapshot?.elapsedSeconds == frozenSeconds)
    }

    @MainActor @Test
    func beginTurn_WhenFollowUpStarts_ResumesElapsedSnapshots() async throws {
        let presentation = AgentRunPresentation(elapsedTickInterval: .milliseconds(20))
        let runID = UUID()
        presentation.start(
            runID: runID,
            profile: try makeAgentProfile(),
            prompt: "First turn")
        defer { presentation.shutdown() }
        presentation.completeTurn(
            runID: runID,
            result: AgentRunResult(stopReason: .endTurn))

        presentation.beginTurn(runID: runID)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(300))
        while presentation.snapshot?.elapsedSeconds == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(presentation.snapshot?.phase == .running)
        #expect((presentation.snapshot?.elapsedSeconds ?? 0) > 0)
    }

    private func makeAgentProfile() throws -> WakeProfile {
        try WakeProfile(
            wakePhrase: "computer",
            action: .agent(AgentHarnessConfiguration(
                preset: .codex,
                displayName: "Codex",
                executablePath: "/usr/bin/env",
                arguments: ["codex-acp"],
                workingDirectory: "/tmp",
                permissionPolicy: .ask)),
            accent: .purple)
    }
}

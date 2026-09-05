// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationApp
@testable import VoiceActivationCore


extension AgentConversationAudioPresenterTests {
    @MainActor @Test func lifecycle_WhenToolsTransition_PlaysEachActivityCueOnce() throws {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { true },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))

        presenter.handle(.event(
            runID: runID,
            event: .toolCall(AgentToolCall(
                id: "read",
                title: "Read files",
                kind: .read,
                status: .pending))))
        presenter.handle(.event(
            runID: runID,
            event: .toolCallUpdate(AgentToolCallUpdate(
                id: "read",
                status: .inProgress))))
        presenter.handle(.event(
            runID: runID,
            event: .toolCallUpdate(AgentToolCallUpdate(
                id: "read",
                status: .completed))))
        presenter.handle(.event(
            runID: runID,
            event: .toolCallUpdate(AgentToolCallUpdate(
                id: "read",
                status: .completed))))
        presenter.handle(.event(
            runID: runID,
            event: .toolCall(AgentToolCall(id: "edit", title: "Edit file"))))
        presenter.handle(.event(
            runID: runID,
            event: .toolCallUpdate(AgentToolCallUpdate(
                id: "edit",
                status: .failed))))

        #expect(player.activitySounds == [
            .toolStarted, .toolCompleted, .toolStarted, .toolFailed,
        ])
    }

    @MainActor @Test func lifecycle_WhenActivitySoundsAreDisabled_PlaysNoToolCues() throws {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { false },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))

        presenter.handle(.event(
            runID: runID,
            event: .toolCall(AgentToolCall(id: "tool", title: "Tool"))))
        presenter.handle(.event(
            runID: runID,
            event: .toolCallUpdate(AgentToolCallUpdate(
                id: "tool",
                status: .completed))))

        #expect(player.activitySounds.isEmpty)
    }

    @MainActor @Test func lifecycle_WhenVoiceCancelsConversation_ReadsStoppedAcknowledgement() throws {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { true },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))

        presenter.handle(.completed(
            runID: runID,
            result: AgentRunResult(stopReason: .cancelled)))

        #expect(player.spoken.map(\.text) == ["Stopped."])
        #expect(player.spoken.map(\.localeID) == ["en-US"])
    }

    @MainActor @Test func lifecycle_WhenAudioOptionsAreDisabled_ProducesNoPlayback() throws {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { false },
            playsWorkingSound: { false },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))
        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(messageID: nil, text: "Answer")))
        presenter.handle(.turnCompleted(
            runID: runID,
            result: AgentRunResult(stopReason: .endTurn)))

        #expect(player.workingStates.allSatisfy { !$0 })
        #expect(player.spoken.isEmpty)
    }

    @MainActor @Test func lifecycle_WhenPermissionIsRequested_SilencesWorkingCue() throws {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { true },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))
        let request = AgentPermissionRequest(
            turnToken: AgentTurnToken(),
            requestID: .integer(4),
            toolCall: AgentToolCallUpdate(
                id: "tool",
                title: "Edit",
                kind: .edit,
                status: .pending),
            options: [])

        presenter.handle(.event(runID: runID, event: .permissionRequested(request)))

        #expect(player.workingStates.last == false)
    }

    @MainActor @Test func permissionResolution_WhenCurrentRunContinues_RestartsWorkingCue() throws {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { true },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))
        presenter.handle(.event(
            runID: runID,
            event: .permissionRequested(AgentPermissionRequest(
                turnToken: AgentTurnToken(),
                requestID: .integer(4),
                toolCall: AgentToolCallUpdate(id: "tool", title: "Edit"),
                options: []))))

        presenter.resumeAfterPermission(runID: runID)

        #expect(player.workingStates.suffix(2) == [false, true])
    }

    @MainActor @Test func refreshSettings_WhenRunHasFailed_DoesNotRestartWorkingCue() throws {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { true },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))
        presenter.handle(.failed(runID: runID, message: "Failed"))

        presenter.refreshSettings()

        #expect(player.workingStates.last == false)
    }

    @MainActor @Test func refreshSettings_WhenRepliesAreDisabled_CancelsPendingSpeechFlush()
        async throws
    {
        let player = AgentConversationAudioSpy()
        var readsReplies = true
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { readsReplies },
            playsWorkingSound: { false },
            localeID: { "en-US" })
        let runID = UUID()
        presenter.handle(.started(
            runID: runID,
            profile: try agentProfile(),
            prompt: "Question"))
        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer", text: "Not yet complete")))

        readsReplies = false
        presenter.refreshSettings()
        try await Task.sleep(for: .milliseconds(450))

        #expect(player.spoken.isEmpty)
    }

}

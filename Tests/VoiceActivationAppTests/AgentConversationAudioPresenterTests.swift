import Foundation
import Testing
@testable import VoiceActivationApp
@testable import VoiceActivationCore

@MainActor
private final class AgentConversationAudioSpy: AgentConversationAudioPlaying {
    var onSpeakingChange: ((Bool) -> Void)?
    private(set) var workingStates: [Bool] = []
    private(set) var spoken: [(text: String, localeID: String)] = []
    private(set) var stopSpeakingCount = 0
    private(set) var stopAllCount = 0

    func setWorking(_ working: Bool) {
        workingStates.append(working)
    }

    func speak(_ text: String, localeID: String) {
        spoken.append((text, localeID))
    }

    func stopSpeaking() {
        stopSpeakingCount += 1
    }

    func stopAll() {
        stopAllCount += 1
    }
}

struct AgentConversationAudioPresenterTests {
    @MainActor @Test func lifecycle_WhenTurnCompletes_ReadsMarkdownReplyAndTracksWorkingState() throws {
        let player = AgentConversationAudioSpy()
        let presenter = AgentConversationAudioPresenter(
            player: player,
            readsReplies: { true },
            playsWorkingSound: { true },
            localeID: { "en-GB" })
        let runID = UUID()
        let profile = try agentProfile()

        presenter.handle(.started(runID: runID, profile: profile, prompt: "Question"))
        presenter.handle(.event(
            runID: runID,
            event: .thoughtDelta(messageID: "thought", text: "Considering")))
        presenter.handle(.event(
            runID: runID,
            event: .agentMessageDelta(messageID: "answer", text: "**Done**")))
        presenter.handle(.turnCompleted(
            runID: runID,
            result: AgentRunResult(stopReason: .endTurn)))

        #expect(player.workingStates == [true, true, true, false])
        #expect(player.spoken.count == 1)
        #expect(player.spoken.first?.text == "Done")
        #expect(player.spoken.first?.localeID == "en-GB")
    }

    @MainActor @Test func lifecycle_WhenFollowUpInterruptsTurn_StopsSpeechAndRestartsWorkingCue() throws {
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
            prompt: "First"))
        let previousStopCount = player.stopSpeakingCount

        presenter.handle(.followUpSubmitted(runID: runID, prompt: "Second"))

        #expect(player.stopSpeakingCount == previousStopCount + 1)
        #expect(player.workingStates.last == true)
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

    @MainActor
    private func agentProfile() throws -> WakeProfile {
        try WakeProfile(
            wakePhrase: "agent",
            action: .agent(AgentHarnessConfiguration(
                preset: .codex,
                displayName: "Codex",
                executablePath: "/usr/bin/true",
                arguments: [],
                workingDirectory: "/tmp",
                permissionPolicy: .ask)),
            accent: .purple)
    }
}

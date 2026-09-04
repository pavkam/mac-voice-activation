import Testing
import VoiceActivationCore
@testable import VoiceActivationApp

struct MenuStatusPresentationTests {
    @Test func make_WhenListeningIsExplicitlyDisabled_ShowsPaused() {
        let presentation = MenuStatusPresentation.make(
            state: .disabled,
            enabledProfileCount: 2,
            isListeningEnabled: false)

        #expect(presentation.title == "Paused")
        #expect(presentation.detail == "Wake phrase listening is off")
        #expect(presentation.symbolName == "pause.fill")
        #expect(presentation.isError == false)
    }

    @Test func make_WhenListeningIsEnabledDuringStartup_DoesNotClaimItIsPaused() {
        let presentation = MenuStatusPresentation.make(
            state: .disabled,
            enabledProfileCount: 2,
            isListeningEnabled: true)

        #expect(presentation.title == "Starting")
        #expect(presentation.detail == "Preparing wake phrase listening")
        #expect(presentation.symbolName == "waveform")
        #expect(presentation.isError == false)
    }

    @Test func make_WhenListeningIsEnabledWithoutActiveProfiles_ExplainsWhatIsMissing() {
        let presentation = MenuStatusPresentation.make(
            state: .disabled,
            enabledProfileCount: 0,
            isListeningEnabled: true)

        #expect(presentation.title == "No active wake phrases")
        #expect(presentation.detail == "Enable a profile to start listening")
        #expect(presentation.symbolName == "waveform.slash")
        #expect(presentation.isError == false)
    }

    @Test func make_WhenListening_DescribesEnabledWakePhrases() {
        let presentation = MenuStatusPresentation.make(
            state: .listening,
            enabledProfileCount: 2,
            isListeningEnabled: true)

        #expect(presentation.title == "Ready")
        #expect(presentation.detail == "Listening for 2 wake phrases")
        #expect(presentation.symbolName == "waveform")
        #expect(presentation.isError == false)
    }

    @Test func make_WhenCapturing_PromptsForCommand() {
        let presentation = MenuStatusPresentation.make(
            state: .capturing,
            enabledProfileCount: 1,
            isListeningEnabled: true)

        #expect(presentation.title == "Listening now")
        #expect(presentation.detail == "Speak your command")
        #expect(presentation.symbolName == "waveform.badge.mic")
        #expect(presentation.isError == false)
    }

    @Test func make_WhenFailed_ShowsFailureMessage() {
        let presentation = MenuStatusPresentation.make(
            state: .failed("Microphone unavailable"),
            enabledProfileCount: 1,
            isListeningEnabled: true)

        #expect(presentation.title == "Needs attention")
        #expect(presentation.detail == "Microphone unavailable")
        #expect(presentation.symbolName == "exclamationmark.triangle.fill")
        #expect(presentation.isError)
    }

    @Test func make_WhenConversationIsWaiting_DescribesLiveFollowUp() {
        let presentation = MenuStatusPresentation.make(
            state: .executing,
            enabledProfileCount: 1,
            isListeningEnabled: true,
            agentPhase: .listening)

        #expect(presentation.title == "In conversation")
        #expect(presentation.detail == "Listening for a follow-up")
        #expect(presentation.symbolName == "waveform.badge.mic")
    }

    @Test func make_WhenAgentTurnIsRunning_ExplainsThatSpeechRemainsAvailable() {
        let presentation = MenuStatusPresentation.make(
            state: .executing,
            enabledProfileCount: 1,
            isListeningEnabled: true,
            agentPhase: .running)

        #expect(presentation.title == "Agent working")
        #expect(presentation.detail == "You can keep speaking")
        #expect(presentation.symbolName == "sparkles")
    }
}

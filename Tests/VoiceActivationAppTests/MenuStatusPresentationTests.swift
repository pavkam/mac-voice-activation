import Testing
import VoiceActivationCore
@testable import VoiceActivationApp

struct MenuStatusPresentationTests {
    @Test func make_WhenListening_DescribesEnabledWakePhrases() {
        let presentation = MenuStatusPresentation.make(
            state: .listening,
            enabledProfileCount: 2)

        #expect(presentation.title == "Ready")
        #expect(presentation.detail == "Listening for 2 wake phrases")
        #expect(presentation.symbolName == "waveform")
        #expect(presentation.isError == false)
    }

    @Test func make_WhenCapturing_PromptsForCommand() {
        let presentation = MenuStatusPresentation.make(
            state: .capturing,
            enabledProfileCount: 1)

        #expect(presentation.title == "Listening now")
        #expect(presentation.detail == "Speak your command")
        #expect(presentation.symbolName == "waveform.badge.mic")
        #expect(presentation.isError == false)
    }

    @Test func make_WhenFailed_ShowsFailureMessage() {
        let presentation = MenuStatusPresentation.make(
            state: .failed("Microphone unavailable"),
            enabledProfileCount: 1)

        #expect(presentation.title == "Needs attention")
        #expect(presentation.detail == "Microphone unavailable")
        #expect(presentation.symbolName == "exclamationmark.triangle.fill")
        #expect(presentation.isError)
    }
}

import Testing
@testable import VoiceActivationCore

struct WakePhraseMatcherTests {
    @Test func command_WhenPhraseStartsTranscript_ReturnsFollowingText() {
        #expect(WakePhraseMatcher.command(in: "computer open the dashboard", wakePhrase: "computer") == "open the dashboard")
    }

    @Test func command_WhenPhraseHasDifferentCaseAndPunctuation_ReturnsFollowingText() {
        #expect(WakePhraseMatcher.command(in: "Computer, show alerts", wakePhrase: "computer") == "show alerts")
    }

    @Test func command_WhenPhraseIsMultiWord_ReturnsFollowingText() {
        #expect(WakePhraseMatcher.command(in: "hey computer play music", wakePhrase: "hey computer") == "play music")
    }

    @Test func command_WhenPhraseIsInsideAnotherWord_DoesNotMatch() {
        #expect(WakePhraseMatcher.command(in: "supercomputer open dashboard", wakePhrase: "computer") == nil)
    }

    @Test func command_WhenOnlyPhraseWasHeard_ReturnsEmptyCommand() {
        #expect(WakePhraseMatcher.command(in: "computer!", wakePhrase: "computer") == "")
    }

    @Test func command_WhenPhraseOccursAfterOtherSpeech_DoesNotMatch() {
        #expect(WakePhraseMatcher.command(in: "please computer open dashboard", wakePhrase: "computer") == nil)
    }
}

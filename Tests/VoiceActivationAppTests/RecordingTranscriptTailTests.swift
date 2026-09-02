import Testing
@testable import VoiceActivationApp

struct RecordingTranscriptTailTests {
    @Test func format_WhenTranscriptFits_PreservesTranscript() {
        #expect(RecordingTranscriptTail.format("open the calendar", maximumLength: 24) == "open the calendar")
    }

    @Test func format_WhenTranscriptExceedsLimit_KeepsNewestCompleteWords() {
        let transcript = "one two three four five six seven"

        let result = RecordingTranscriptTail.format(transcript, maximumLength: 24)

        #expect(result == "… four five six seven")
        #expect(result.count <= 24)
    }

    @Test func format_WhenNewestWordExceedsLimit_KeepsNewestCharacters() {
        let transcript = "say supercalifragilistic"

        let result = RecordingTranscriptTail.format(transcript, maximumLength: 10)

        #expect(result == "…agilistic")
        #expect(result.count == 10)
    }
}

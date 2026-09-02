import Testing
@testable import VoiceActivationApp

struct MenuTranscriptSummaryTests {
    @Test func format_WhenTranscriptExceedsLimit_TruncatesWithEllipsis() {
        let transcript = String(repeating: "word ", count: 30)

        let result = MenuTranscriptSummary.format(transcript, maximumLength: 24)

        #expect(result == "word word word word wor…")
        #expect(result.count == 24)
    }

    @Test func format_WhenTranscriptFitsLimit_PreservesText() {
        #expect(MenuTranscriptSummary.format("open calendar", maximumLength: 24) == "open calendar")
    }
}

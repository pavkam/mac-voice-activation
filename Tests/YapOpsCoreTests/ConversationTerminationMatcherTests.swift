// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Testing
@testable import YapOpsCore

struct ConversationTerminationMatcherTests {
    private let phrases = AppPreferences.defaultTerminalPhrases

    @Test func matches_WhenUtteranceIsExactlyASingleWordPhrase_ReturnsTrue() {
        #expect(ConversationTerminationMatcher.matches("cancel", phrases: phrases))
        #expect(ConversationTerminationMatcher.matches("STOP!", phrases: phrases))
        #expect(ConversationTerminationMatcher.matches("close.", phrases: phrases))
    }

    @Test func matches_WhenUtteranceIsExactlyAMultiWordPhrase_ReturnsTrue() {
        #expect(ConversationTerminationMatcher.matches("thank you", phrases: phrases))
        #expect(ConversationTerminationMatcher.matches("Thank You!", phrases: phrases))
        #expect(ConversationTerminationMatcher.matches("that's it", phrases: phrases))
        #expect(ConversationTerminationMatcher.matches("that’s it", phrases: phrases))
    }

    @Test func matches_WhenPhraseIsOnlyPartOfTheUtterance_ReturnsFalse() {
        #expect(!ConversationTerminationMatcher.matches("thanks for checking", phrases: phrases))
        #expect(!ConversationTerminationMatcher.matches("great, and then what", phrases: phrases))
        #expect(!ConversationTerminationMatcher.matches("please cancel that", phrases: phrases))
    }

    @Test func matches_WhenUtteranceIsEmptyOrBlank_ReturnsFalse() {
        #expect(!ConversationTerminationMatcher.matches("", phrases: phrases))
        #expect(!ConversationTerminationMatcher.matches("   ", phrases: phrases))
        #expect(!ConversationTerminationMatcher.matches("123", phrases: phrases))
    }

    @Test func matches_WhenPhraseListIsEmpty_ReturnsFalse() {
        #expect(!ConversationTerminationMatcher.matches("cancel", phrases: []))
    }

    /// A blank entry in a user-edited list must not swallow every utterance.
    @Test func matches_WhenPhraseListContainsABlankEntry_IgnoresIt() {
        #expect(!ConversationTerminationMatcher.matches("some request", phrases: ["", "  "]))
    }

    @Test func matches_IsCaseDiacriticAndWidthInsensitive() {
        #expect(ConversationTerminationMatcher.matches("Cancél", phrases: ["cancel"]))
        #expect(ConversationTerminationMatcher.matches("ｃａｎｃｅｌ", phrases: ["cancel"]))
    }
}

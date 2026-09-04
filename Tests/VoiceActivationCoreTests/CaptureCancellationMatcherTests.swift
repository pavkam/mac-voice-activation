// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Testing
@testable import VoiceActivationCore

struct CaptureCancellationMatcherTests {
    @Test func matches_WhenCompletedTranscriptIsSingleCancellationWord_ReturnsTrue() {
        #expect(CaptureCancellationMatcher.matches("cancel", isComplete: true))
        #expect(CaptureCancellationMatcher.matches("STOP!", isComplete: true))
        #expect(CaptureCancellationMatcher.matches("dismiss.", isComplete: true))
    }

    @Test func matches_WhenSingleCancellationWordIsPartial_ReturnsFalse() {
        #expect(!CaptureCancellationMatcher.matches("stop", isComplete: false))
    }

    @Test func matches_WhenCancellationWordRepeatsInPartialTranscript_ReturnsTrue() {
        #expect(CaptureCancellationMatcher.matches("cancel, cancel", isComplete: false))
        #expect(CaptureCancellationMatcher.matches("please stop stop now", isComplete: false))
        #expect(CaptureCancellationMatcher.matches("dismiss dismiss dismiss", isComplete: false))
    }

    @Test func matches_WhenCancellationWordsDifferOrAreNotAdjacent_ReturnsFalse() {
        #expect(!CaptureCancellationMatcher.matches("stop cancel", isComplete: false))
        #expect(!CaptureCancellationMatcher.matches("stop this stop", isComplete: false))
    }

    @Test func matches_WhenCancellationWordStartsANormalCommand_ReturnsFalse() {
        #expect(!CaptureCancellationMatcher.matches("stop the music", isComplete: true))
        #expect(!CaptureCancellationMatcher.matches("dismiss the alert", isComplete: true))
    }

    @Test func matches_WhenCancellationWordHasNumericContent_ReturnsFalse() {
        #expect(!CaptureCancellationMatcher.matches("stop 123", isComplete: true))
        #expect(!CaptureCancellationMatcher.matches("stop 2 stop", isComplete: false))
    }
}

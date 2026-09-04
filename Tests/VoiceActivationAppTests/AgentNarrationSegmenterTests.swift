// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Testing
@testable import VoiceActivationApp

struct AgentNarrationSegmenterTests {
    @MainActor @Test
    func markSemanticBoundary_WhenMessageHasNoPunctuation_EmitsItImmediately() {
        let segmenter = AgentNarrationSegmenter(flushDelay: .seconds(30))
        var segments: [String] = []
        segmenter.onSegment = { segments.append($0) }

        segmenter.append(messageID: "progress", text: "Let me check this")
        #expect(segments.isEmpty)
        segmenter.markSemanticBoundary()

        #expect(segments == ["Let me check this"])
        segmenter.reset()
    }

    @MainActor @Test func append_WhenMessageIdentityChanges_DoesNotMergeSeparateMessages() {
        let segmenter = AgentNarrationSegmenter(flushDelay: .seconds(30))
        var segments: [String] = []
        segmenter.onSegment = { segments.append($0) }

        segmenter.append(messageID: "progress", text: "Let me check")
        segmenter.append(messageID: "answer", text: "Found it")
        segmenter.finish()

        #expect(segments == ["Let me check", "Found it"])
    }

    @MainActor @Test
    func append_WhenUnclosedCodeFencePrecedesANewMessage_FinalizesBothSeparately() {
        let segmenter = AgentNarrationSegmenter(flushDelay: .seconds(30))
        var segments: [String] = []
        segmenter.onSegment = { segments.append($0) }

        segmenter.append(messageID: "progress", text: "```sh\nprivate-command")
        segmenter.append(messageID: "answer", text: "Found it")
        segmenter.finish()

        #expect(segments == ["Code block omitted.", "Found it"])
    }
}

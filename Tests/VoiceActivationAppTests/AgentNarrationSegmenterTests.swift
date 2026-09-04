// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Testing

@testable import VoiceActivationApp
@testable import VoiceActivationCore

struct AgentNarrationSegmenterTests {
    @MainActor @Test func segments_WhenEmitted_RecordBoundaryTimingWithoutResponseText() {
        let diagnostics = AppDiagnosticRecorderSpy()
        let segmenter = AgentNarrationSegmenter(
            flushDelay: .seconds(30),
            diagnostics: diagnostics)
        segmenter.append(messageID: "progress", text: "Let me check this")

        segmenter.markSemanticBoundary()

        let entry = diagnostics.snapshot().last {
            $0.event == "narration.segment_emitted"
        }
        #expect(entry?.fields["reason"] == "semantic_boundary")
        #expect(entry?.fields["character_count"] == "17")
        #expect(entry?.fields["response_text"] == nil)
    }

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

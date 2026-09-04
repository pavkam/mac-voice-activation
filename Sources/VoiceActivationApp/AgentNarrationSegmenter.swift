// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import VoiceActivationCore

@MainActor
final class AgentNarrationSegmenter {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private static let maximumBufferedCharacters = 20_000

    private enum BoundaryReason: String {
        case sentence = "sentence_or_newline"
        case semantic = "semantic_boundary"
        case newMessage = "new_message"
        case timer
        case finish
    }

    var onSegment: ((String) -> Void)?

    private let flushDelay: Duration
    private let sleep: Sleep
    private let diagnostics: any VoiceActivationDiagnosticRecording
    private var messageID: String?
    private var markdown = ""
    private var bufferStartedAtUptime: UInt64?
    private var flushTask: Task<Void, Never>?

    init(
        flushDelay: Duration = .milliseconds(350),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.flushDelay = flushDelay
        self.sleep = sleep
        self.diagnostics = diagnostics
    }

    func append(messageID: String?, text: String) {
        guard !text.isEmpty else {
            diagnostics.record(
                category: .audio,
                event: "narration.delta_ignored",
                fields: ["reason": "empty"])
            return
        }
        if !markdown.isEmpty, isNewMessage(messageID) {
            flushAtSemanticBoundary(reason: .newMessage)
        }
        if markdown.isEmpty {
            self.messageID = messageID
            bufferStartedAtUptime = DispatchTime.now().uptimeNanoseconds
        }
        markdown.append(text)
        diagnostics.record(
            category: .audio,
            event: "narration.delta_received",
            fields: [
                "delta_character_count": String(text.count),
                "buffered_character_count": String(markdown.count),
                "has_message_id": String(messageID != nil),
            ])
        emitCompleteSegments()
        boundBuffer()
        scheduleFlush()
    }

    func markSemanticBoundary() {
        flushAtSemanticBoundary(reason: .semantic)
    }

    func finish() {
        cancelFlush()
        emit(markdown, reason: .finish)
        markdown = ""
        messageID = nil
        bufferStartedAtUptime = nil
    }

    func reset() {
        let discardedCharacterCount = markdown.count
        cancelFlush()
        markdown = ""
        messageID = nil
        bufferStartedAtUptime = nil
        diagnostics.record(
            category: .audio,
            event: "narration.buffer_reset",
            fields: ["discarded_character_count": String(discardedCharacterCount)])
    }

    private func isNewMessage(_ nextMessageID: String?) -> Bool {
        switch (messageID, nextMessageID) {
        case (nil, nil):
            false
        case (let current, let next):
            current != next
        }
    }

    private func emitCompleteSegments() {
        while let boundary = Self.firstSpeechBoundary(in: markdown) {
            let segment = String(markdown[..<boundary])
            markdown.removeSubrange(..<boundary)
            emit(segment, reason: .sentence)
            bufferStartedAtUptime =
                markdown.isEmpty
                ? nil
                : DispatchTime.now().uptimeNanoseconds
        }
        if markdown.isEmpty {
            messageID = nil
            cancelFlush()
        }
    }

    private func flushAtSemanticBoundary(reason: BoundaryReason) {
        guard !markdown.isEmpty else { return }
        cancelFlush()
        emit(markdown, reason: reason)
        markdown = ""
        messageID = nil
        bufferStartedAtUptime = nil
    }

    private func emit(_ markdown: String, reason: BoundaryReason) {
        let spokenText = AgentMarkdownFormatter.spokenText(from: markdown)
        guard !spokenText.isEmpty else {
            diagnostics.record(
                category: .audio,
                event: "narration.segment_ignored",
                fields: [
                    "reason": reason.rawValue,
                    "markdown_character_count": String(markdown.count),
                ])
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let ageMilliseconds =
            bufferStartedAtUptime.map {
                now >= $0 ? (now - $0) / 1_000_000 : 0
            } ?? 0
        diagnostics.record(
            category: .audio,
            event: "narration.segment_emitted",
            fields: [
                "reason": reason.rawValue,
                "character_count": String(spokenText.count),
                "markdown_character_count": String(markdown.count),
                "buffer_age_ms": String(ageMilliseconds),
            ])
        onSegment?(spokenText)
    }

    private func boundBuffer() {
        guard markdown.count > Self.maximumBufferedCharacters else { return }
        let originalCharacterCount = markdown.count
        if let activeFence = Self.unclosedFenceMarker(in: markdown) {
            markdown = "\(activeFence)\n"
            diagnostics.record(
                category: .audio,
                event: "narration.buffer_bounded",
                level: .warning,
                fields: [
                    "original_character_count": String(originalCharacterCount),
                    "retained_character_count": String(markdown.count),
                    "inside_code_fence": "true",
                ])
            return
        }
        markdown = String(markdown.suffix(Self.maximumBufferedCharacters))
        diagnostics.record(
            category: .audio,
            event: "narration.buffer_bounded",
            level: .warning,
            fields: [
                "original_character_count": String(originalCharacterCount),
                "retained_character_count": String(markdown.count),
                "inside_code_fence": "false",
            ])
    }

    private func scheduleFlush() {
        guard flushTask == nil,
            !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            Self.unclosedFenceMarker(in: markdown) == nil
        else { return }

        let sleep = sleep
        diagnostics.record(
            category: .audio,
            event: "narration.flush_scheduled",
            fields: ["buffered_character_count": String(markdown.count)])
        flushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await sleep(self.flushDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.flushTask = nil
            guard Self.unclosedFenceMarker(in: self.markdown) == nil else { return }
            self.flushAtSemanticBoundary(reason: .timer)
        }
    }

    private func cancelFlush() {
        flushTask?.cancel()
        flushTask = nil
    }

    private static func firstSpeechBoundary(in text: String) -> String.Index? {
        var activeFence: String?
        var lineStart = text.startIndex

        while lineStart < text.endIndex {
            let newline = text[lineStart...].firstIndex(of: "\n")
            let lineEnd = newline ?? text.endIndex
            let trimmedLine = text[lineStart..<lineEnd]
                .drop(while: { $0 == " " || $0 == "\t" })
            let wasInsideFence = activeFence != nil

            if let fence = activeFence {
                if trimmedLine.hasPrefix(fence) {
                    activeFence = nil
                }
            } else if let fence = fenceMarker(in: trimmedLine) {
                activeFence = fence
            }

            if !wasInsideFence, activeFence == nil {
                var index = lineStart
                while index < lineEnd {
                    let character = text[index]
                    let boundary = text.index(after: index)
                    if character == "." || character == "!" || character == "?",
                        boundary == lineEnd || text[boundary].isWhitespace
                    {
                        return boundary
                    }
                    index = boundary
                }
            }

            guard let newline else { break }
            let boundary = text.index(after: newline)
            if activeFence == nil {
                return boundary
            }
            lineStart = boundary
        }
        return nil
    }

    private static func unclosedFenceMarker(in text: String) -> String? {
        var activeFence: String?
        var lineStart = text.startIndex

        while lineStart < text.endIndex {
            let newline = text[lineStart...].firstIndex(of: "\n")
            let lineEnd = newline ?? text.endIndex
            let trimmedLine = text[lineStart..<lineEnd]
                .drop(while: { $0 == " " || $0 == "\t" })

            if let fence = activeFence {
                if trimmedLine.hasPrefix(fence) {
                    activeFence = nil
                }
            } else if let fence = fenceMarker(in: trimmedLine) {
                activeFence = fence
            }

            guard let newline else { break }
            lineStart = text.index(after: newline)
        }

        return activeFence
    }

    private static func fenceMarker(in line: Substring) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }
}

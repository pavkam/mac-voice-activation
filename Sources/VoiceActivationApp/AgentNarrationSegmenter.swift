// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

@MainActor
final class AgentNarrationSegmenter {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private static let maximumBufferedCharacters = 20_000

    var onSegment: ((String) -> Void)?

    private let flushDelay: Duration
    private let sleep: Sleep
    private var messageID: String?
    private var markdown = ""
    private var flushTask: Task<Void, Never>?

    init(
        flushDelay: Duration = .milliseconds(350),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) })
    {
        self.flushDelay = flushDelay
        self.sleep = sleep
    }

    func append(messageID: String?, text: String) {
        guard !text.isEmpty else { return }
        if !markdown.isEmpty, isNewMessage(messageID) {
            flushAtSemanticBoundary()
        }
        if markdown.isEmpty {
            self.messageID = messageID
        }
        markdown.append(text)
        emitCompleteSegments()
        boundBuffer()
        scheduleFlush()
    }

    func markSemanticBoundary() {
        flushAtSemanticBoundary()
    }

    func finish() {
        cancelFlush()
        emit(markdown)
        markdown = ""
        messageID = nil
    }

    func reset() {
        cancelFlush()
        markdown = ""
        messageID = nil
    }

    private func isNewMessage(_ nextMessageID: String?) -> Bool {
        switch (messageID, nextMessageID) {
        case (nil, nil):
            false
        case let (current, next):
            current != next
        }
    }

    private func emitCompleteSegments() {
        while let boundary = Self.firstSpeechBoundary(in: markdown) {
            let segment = String(markdown[..<boundary])
            markdown.removeSubrange(..<boundary)
            emit(segment)
        }
        if markdown.isEmpty {
            messageID = nil
            cancelFlush()
        }
    }

    private func flushAtSemanticBoundary() {
        guard !markdown.isEmpty else { return }
        cancelFlush()
        emit(markdown)
        markdown = ""
        messageID = nil
    }

    private func emit(_ markdown: String) {
        let spokenText = AgentMarkdownFormatter.spokenText(from: markdown)
        guard !spokenText.isEmpty else { return }
        onSegment?(spokenText)
    }

    private func boundBuffer() {
        guard markdown.count > Self.maximumBufferedCharacters else { return }
        if let activeFence = Self.unclosedFenceMarker(in: markdown) {
            markdown = "\(activeFence)\n"
            return
        }
        markdown = String(markdown.suffix(Self.maximumBufferedCharacters))
    }

    private func scheduleFlush() {
        guard flushTask == nil,
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.unclosedFenceMarker(in: markdown) == nil
        else { return }

        let sleep = sleep
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
            self.flushAtSemanticBoundary()
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
                    if (character == "." || character == "!" || character == "?"),
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

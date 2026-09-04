// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

enum AgentMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedListItem(depth: Int, text: String)
    case orderedListItem(depth: Int, number: String, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case divider
}

enum AgentMarkdownFormatter {
    static func attributedString(from markdown: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch {
            return AttributedString(markdown)
        }
    }

    static func blocks(from markdown: String) -> [AgentMarkdownBlock] {
        let lines = markdown.split(
            separator: "\n",
            omittingEmptySubsequences: false).map(String.init)
        var blocks: [AgentMarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String]?
        var codeLanguage: String?
        var codeFence: String?

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            guard let codeLines else { return }
            blocks.append(.code(
                language: codeLanguage,
                text: codeLines.joined(separator: "\n")))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let activeFence = codeFence {
                if trimmed.hasPrefix(activeFence) {
                    flushCode()
                    codeLines = nil
                    codeLanguage = nil
                    codeFence = nil
                } else {
                    codeLines?.append(line)
                }
                continue
            }

            if let fence = fenceMarker(in: trimmed) {
                flushParagraph()
                codeFence = fence
                let language = trimmed.dropFirst(fence.count)
                    .trimmingCharacters(in: .whitespaces)
                codeLanguage = language.isEmpty ? nil : language
                codeLines = []
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = heading(in: line) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if let item = unorderedListItem(in: line) {
                flushParagraph()
                blocks.append(.unorderedListItem(depth: item.depth, text: item.text))
                continue
            }

            if let item = orderedListItem(in: line) {
                flushParagraph()
                blocks.append(.orderedListItem(
                    depth: item.depth,
                    number: item.number,
                    text: item.text))
                continue
            }

            if let quote = quote(in: line) {
                flushParagraph()
                blocks.append(.quote(quote))
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                continue
            }

            paragraphLines.append(line)
        }

        if codeLines != nil {
            flushCode()
        }
        flushParagraph()
        return blocks
    }

    static func spokenText(from markdown: String) -> String {
        blocks(from: markdown).compactMap { block in
            switch block {
            case let .heading(_, text),
                 let .paragraph(text),
                 let .unorderedListItem(_, text),
                 let .orderedListItem(_, _, text),
                 let .quote(text):
                inlinePlainText(text)
            case .code:
                "Code block omitted."
            case .divider:
                nil
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private static func inlinePlainText(_ markdown: String) -> String {
        String(attributedString(from: markdown).characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fenceMarker(in line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let content = line.drop(while: { $0 == " " || $0 == "\t" })
        let level = content.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let remainder = content.dropFirst(level)
        guard remainder.first == " " || remainder.first == "\t" else { return nil }
        return (level, remainder.drop(while: { $0 == " " || $0 == "\t" }).description)
    }

    private static func unorderedListItem(in line: String) -> (depth: Int, text: String)? {
        let indentation = line.prefix(while: { $0 == " " }).count
        let content = line.dropFirst(indentation)
        let markers = ["- ", "* ", "+ "]
        guard let marker = markers.first(where: { content.hasPrefix($0) }) else { return nil }
        return (min(indentation / 2, 6), content.dropFirst(marker.count).description)
    }

    private static func orderedListItem(
        in line: String) -> (depth: Int, number: String, text: String)?
    {
        let indentation = line.prefix(while: { $0 == " " }).count
        let content = line.dropFirst(indentation)
        let number = content.prefix(while: { $0.isNumber })
        guard !number.isEmpty else { return nil }
        let remainder = content.dropFirst(number.count)
        guard remainder.hasPrefix(". ") else { return nil }
        return (
            min(indentation / 2, 6),
            number.description,
            remainder.dropFirst(2).description)
    }

    private static func quote(in line: String) -> String? {
        let content = line.drop(while: { $0 == " " || $0 == "\t" })
        guard content.first == ">" else { return nil }
        return content.dropFirst().drop(while: { $0 == " " || $0 == "\t" }).description
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first else { return false }
        guard marker == "-" || marker == "*" || marker == "_" else { return false }
        return compact.allSatisfy { $0 == marker }
    }
}

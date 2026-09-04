// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationApp

struct AgentMarkdownFormatterTests {
    @Test func attributedString_WhenMarkdownContainsInlineFormatting_RendersSemantics() throws {
        let rendered = AgentMarkdownFormatter.attributedString(
            from: "Use **bold** and `code` with [a link](https://example.com).")

        #expect(String(rendered.characters) == "Use bold and code with a link.")
        let intents = rendered.runs.compactMap(\.inlinePresentationIntent)
        #expect(intents.contains { $0.contains(.stronglyEmphasized) })
        #expect(intents.contains { $0.contains(.code) })
        #expect(rendered.runs.contains { $0.link == URL(string: "https://example.com") })
    }

    @Test func blocks_WhenResponseUsesCommonMarkdown_PreservesDocumentStructure() {
        let blocks = AgentMarkdownFormatter.blocks(from: """
            # Result

            - **First** item
            2. Second item

            > Important note

            ```swift
            let answer = 42
            ```
            """)

        #expect(blocks == [
            .heading(level: 1, text: "Result"),
            .unorderedListItem(depth: 0, text: "**First** item"),
            .orderedListItem(depth: 0, number: "2", text: "Second item"),
            .quote("Important note"),
            .code(language: "swift", text: "let answer = 42"),
        ])
    }

    @Test func blocks_WhenCodeFenceIsStillStreaming_RetainsPartialCode() {
        let blocks = AgentMarkdownFormatter.blocks(from: """
            Working:

            ```sh
            swift test --filter AgentRun
            """)

        #expect(blocks == [
            .paragraph("Working:"),
            .code(language: "sh", text: "swift test --filter AgentRun"),
        ])
    }

    @Test func spokenText_WhenResponseIsMarkdown_RemovesFormattingAndSkipsCodeDetails() {
        let spoken = AgentMarkdownFormatter.spokenText(from: """
            # Result

            **Everything** passed. See [the report](https://example.com).

            - First item

            ```sh
            dangerous --flags
            ```
            """)

        #expect(spoken == "Result\nEverything passed. See the report.\nFirst item\nCode block omitted.")
    }
}

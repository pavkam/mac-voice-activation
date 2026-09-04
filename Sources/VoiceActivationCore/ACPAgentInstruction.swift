// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

enum ACPAgentInstruction {
    static let responseStyle = """
        Format every user-facing response as GitHub-flavored Markdown. Use headings, lists, \
        emphasis, links, and fenced code when they improve clarity. Do not wrap the entire \
        response in a code fence.

        Keep progress narration sparse and conversational. Before or between work batches, \
        use at most one short sentence, such as “Let me check.” or “Whoops, I need to \
        initialize this first.” Do not narrate individual tool calls, command details, or \
        routine intermediate results. Put useful detail in the final answer.
        """
}

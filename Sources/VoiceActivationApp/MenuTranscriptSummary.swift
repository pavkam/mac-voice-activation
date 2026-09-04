// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

enum MenuTranscriptSummary {
    static func format(_ transcript: String, maximumLength: Int = 72) -> String {
        guard transcript.count > maximumLength else { return transcript }
        guard maximumLength > 1 else { return "…" }
        return String(transcript.prefix(maximumLength - 1)) + "…"
    }
}

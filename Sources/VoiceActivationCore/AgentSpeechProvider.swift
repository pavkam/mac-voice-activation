// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

public enum AgentSpeechProvider: String, CaseIterable, Codable, Equatable, Sendable {
    case system
    case elevenLabs
}

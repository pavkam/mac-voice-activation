// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

/// The text-to-speech service used to read agent replies.
public enum AgentSpeechProvider: String, CaseIterable, Codable, Equatable, Sendable {
    /// Apple's system speech synthesizer and installed voices.
    case system
    /// ElevenLabs cloud synthesis using the configured credential and voice.
    case elevenLabs
}

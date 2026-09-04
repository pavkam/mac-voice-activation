// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

@testable import VoiceActivationApp

@MainActor
final class SilentAgentSpeechCredentialStore: AgentSpeechCredentialStoring {
    private var apiKey: String?

    init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    func loadElevenLabsAPIKey() async throws -> String? {
        apiKey
    }

    func saveElevenLabsAPIKey(_ apiKey: String?) throws {
        self.apiKey = apiKey
    }
}

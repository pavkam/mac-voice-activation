// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Testing
@testable import VoiceActivationApp

struct AgentSpeechCredentialBootstrapTests {
    @MainActor @Test func importIfRequested_WhenFlagIsAbsent_DoesNotReadOrStore() throws {
        let store = SilentAgentSpeechCredentialStore()
        var readCount = 0

        let imported = try AgentSpeechCredentialBootstrap.importIfRequested(
            arguments: ["VoiceActivation"],
            readCredential: {
                readCount += 1
                return "secret"
            },
            store: store)

        #expect(!imported)
        #expect(readCount == 0)
        #expect(try store.loadElevenLabsAPIKey() == nil)
    }

    @MainActor @Test func importIfRequested_WhenStdinContainsKey_StoresTrimmedValue() throws {
        let store = SilentAgentSpeechCredentialStore()

        let imported = try AgentSpeechCredentialBootstrap.importIfRequested(
            arguments: ["VoiceActivation", "--store-elevenlabs-key-from-stdin"],
            readCredential: { "  secret  " },
            store: store)

        #expect(imported)
        #expect(try store.loadElevenLabsAPIKey() == "secret")
    }

    @MainActor @Test func importIfRequested_WhenStdinIsEmpty_RejectsIt() {
        let store = SilentAgentSpeechCredentialStore()

        #expect(throws: AgentSpeechCredentialBootstrapError.missingCredential) {
            try AgentSpeechCredentialBootstrap.importIfRequested(
                arguments: ["VoiceActivation", "--store-elevenlabs-key-from-stdin"],
                readCredential: { "   " },
                store: store)
        }
    }
}

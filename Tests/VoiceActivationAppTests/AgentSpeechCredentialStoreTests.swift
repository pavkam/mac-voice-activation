// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Testing

@testable import VoiceActivationApp

struct AgentSpeechCredentialStoreTests {
    @Test func accessQueue_WhenOperationRuns_UsesItsDedicatedDispatchQueue() async throws {
        let accessQueue = AgentSpeechCredentialAccessQueue(
            label: "dev.alex.voice-activation.tests.keychain")

        let usedDedicatedQueue = try await accessQueue.perform {
            accessQueue.isExecutingOperation
        }

        #expect(usedDedicatedQueue)
    }

    @MainActor @Test func load_WhenOperationCompletes_RecordsQueueAndOperationBoundaries()
        async throws
    {
        let diagnostics = AppDiagnosticRecorderSpy()
        let store = KeychainAgentSpeechCredentialStore(
            accessQueue: AgentSpeechCredentialAccessQueue(
                label: "dev.alex.voice-activation.tests.credential-load"),
            loadOperation: { "stored-key" },
            diagnostics: diagnostics)

        #expect(try await store.loadElevenLabsAPIKey() == "stored-key")

        let entries = diagnostics.snapshot()
        #expect(entries.map(\.event) == [
            "credential_store.load_queued",
            "credential_store.load_worker_started",
            "credential_store.load_worker_finished",
        ])
        #expect(entries[0].fields["task_priority"] != nil)
        #expect(entries[1].fields["uses_dedicated_queue"] == "true")
        #expect(entries[1].fields["queue_delay_ms"] != nil)
        #expect(entries[2].fields["operation_duration_ms"] != nil)
        #expect(entries[2].fields["has_value"] == "true")
    }
}

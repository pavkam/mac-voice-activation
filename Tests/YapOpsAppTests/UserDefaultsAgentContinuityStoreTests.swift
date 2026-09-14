// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import YapOpsApp
@testable import YapOpsCore

@Suite struct UserDefaultsAgentContinuityStoreTests {
    @Test func save_WhenEnvelopeExceedsBounds_EvictsLeastRecentlyUsedBookmark() async throws {
        try await withStore { store, defaults in
            for index in 0..<64 {
                try await store.save(bookmark: bookmark(index: index))
            }
            _ = try await store.bookmark(for: profileID(0))

            try await store.save(bookmark: bookmark(index: 64))

            let envelope = try persistedEnvelope(defaults)
            #expect(envelope.bookmarks.count == 64)
            #expect(envelope.bookmarks.contains { $0.profileID == profileID(0) })
            #expect(!envelope.bookmarks.contains { $0.profileID == profileID(1) })
            #expect(envelope.bookmarks.contains { $0.profileID == profileID(64) })
        }
    }

    @Test func bookmark_WhenIdentifierExceeds4096Bytes_ThrowsWithoutWriting()
        async throws
    {
        try await withStore { store, defaults in
            let exact = String(repeating: "🦊", count: 1_024)
            try await store.save(bookmark: bookmark(index: 0, sessionID: exact))
            let before = defaults.data(forKey: UserDefaultsAgentContinuityStore.key)

            await expectThrow {
                try await store.save(bookmark: bookmark(index: 1, sessionID: exact + "a"))
            }

            #expect(defaults.data(forKey: UserDefaultsAgentContinuityStore.key) == before)
            #expect(try await store.bookmark(for: profileID(0))?.sessionID == exact)
        }
    }

    @Test func markWorkActive_WhenTurnOrTaskIdentifierCrossesBound_ThrowsWithoutWriting()
        async throws
    {
        try await withStore { store, defaults in
            let exact = String(repeating: "é", count: 2_048)
            let valid = marker(index: 0, turnID: exact, providerTaskID: exact)
            try await store.markWorkActive(valid)
            let before = defaults.data(forKey: UserDefaultsAgentContinuityStore.key)

            await expectThrow {
                try await store.markWorkActive(marker(index: 1, turnID: exact + "a"))
            }
            await expectThrow {
                try await store.markWorkActive(marker(index: 2, providerTaskID: exact + "a"))
            }

            #expect(defaults.data(forKey: UserDefaultsAgentContinuityStore.key) == before)
        }
    }

    @Test func mutations_WhenIdentifierIsEmptyOrFingerprintInvalid_ThrowWithoutWriting()
        async throws
    {
        try await withStore { store, defaults in
            try await store.save(bookmark: bookmark(index: 0))
            let before = defaults.data(forKey: UserDefaultsAgentContinuityStore.key)

            await expectThrow {
                try await store.save(bookmark: bookmark(index: 1, sessionID: ""))
            }
            await expectThrow {
                try await store.save(bookmark: bookmark(index: 1, fingerprint: "ABC"))
            }
            await expectThrow {
                try await store.markWorkActive(marker(index: 1, sessionID: ""))
            }
            await expectThrow {
                try await store.markWorkActive(marker(index: 2, turnID: ""))
            }
            await expectThrow {
                try await store.markWorkActive(marker(index: 3, providerTaskID: ""))
            }

            #expect(defaults.data(forKey: UserDefaultsAgentContinuityStore.key) == before)
        }
    }

    @Test func bookmark_WhenSchemaIsUnknown_ReturnsNilAndDoesNotRewriteData() async throws {
        try await withStore { store, defaults in
            let unknown = Data(#"{"schemaVersion":2,"bookmarks":[],"interruptedWork":[]}"#.utf8)
            defaults.set(unknown, forKey: UserDefaultsAgentContinuityStore.key)

            #expect(try await store.bookmark(for: profileID(0)) == nil)
            #expect(try await store.bookmark(for: profileID(1)) == nil)
            #expect(defaults.data(forKey: UserDefaultsAgentContinuityStore.key) == unknown)

            try await store.save(bookmark: bookmark(index: 2))
            let replacement = try persistedEnvelope(defaults)
            #expect(replacement.schemaVersion == 1)
            #expect(replacement.bookmarks.map(\.profileID) == [profileID(2)])
        }
    }

    @Test func bookmark_WhenPersistedRecordsAreMalformedOrDuplicated_QuarantinesUntilMutation()
        async throws
    {
        try await withStore { store, defaults in
            let duplicate = AgentContinuityEnvelope(
                schemaVersion: 1,
                bookmarks: [bookmark(index: 0), bookmark(index: 0)],
                interruptedWork: [])
            let data = try JSONEncoder().encode(duplicate)
            defaults.set(data, forKey: UserDefaultsAgentContinuityStore.key)

            #expect(try await store.bookmark(for: profileID(0)) == nil)
            #expect(defaults.data(forKey: UserDefaultsAgentContinuityStore.key) == data)

            try await store.remove(profileIDs: [profileID(0)])
            #expect(try persistedEnvelope(defaults) == AgentContinuityEnvelope(
                schemaVersion: 1,
                bookmarks: [],
                interruptedWork: []))
        }
    }

    @Test func bookmark_WhenPersistedJSONIsCorrupt_ReturnsNilWithoutRewriting() async throws {
        try await withStore { store, defaults in
            let corrupt = Data("{not-json".utf8)
            defaults.set(corrupt, forKey: UserDefaultsAgentContinuityStore.key)

            #expect(try await store.bookmark(for: profileID(0)) == nil)
            #expect(defaults.data(forKey: UserDefaultsAgentContinuityStore.key) == corrupt)

            try await store.clearWork(workKey(index: 0))
            #expect(try persistedEnvelope(defaults) == AgentContinuityEnvelope(
                schemaVersion: 1,
                bookmarks: [],
                interruptedWork: []))
        }
    }

    @Test func bookmark_WhenPersistedSchemaContainsUnknownContent_QuarantinesWithoutRewriting()
        async throws
    {
        try await withStore { store, defaults in
            let unknownContent = Data(#"{"schemaVersion":1,"bookmarks":[],"interruptedWork":[],"prompt":"must-not-persist"}"#.utf8)
            defaults.set(unknownContent, forKey: UserDefaultsAgentContinuityStore.key)

            #expect(try await store.bookmark(for: profileID(0)) == nil)
            #expect(defaults.data(forKey: UserDefaultsAgentContinuityStore.key) == unknownContent)

            try await store.remove(profileIDs: [])
            let replacement = try #require(
                defaults.data(forKey: UserDefaultsAgentContinuityStore.key))
            #expect(!String(decoding: replacement, as: UTF8.self).contains("must-not-persist"))
        }
    }

    @Test func saveAndMark_WhenExactIdentityAlreadyExists_ReplacesInsteadOfDuplicating()
        async throws
    {
        try await withStore { store, defaults in
            try await store.save(bookmark: bookmark(index: 0, sessionID: "old"))
            try await store.save(bookmark: bookmark(index: 0, sessionID: "new"))
            let key = workKey(index: 0)
            try await store.markWorkActive(AgentInterruptedWorkMarker(
                key: key,
                turnID: "old-turn",
                state: .active))
            try await store.markWorkActive(AgentInterruptedWorkMarker(
                key: key,
                turnID: "new-turn",
                state: .active))

            let envelope = try persistedEnvelope(defaults)
            #expect(envelope.bookmarks.count == 1)
            #expect(envelope.bookmarks.first?.sessionID == "new")
            #expect(envelope.interruptedWork.count == 1)
            #expect(envelope.interruptedWork.first?.turnID == "new-turn")
        }
    }

    @Test func reconcileInterruptedWork_WhenMarkerWasActive_PersistsInterruptedState()
        async throws
    {
        try await withStore { store, defaults in
            try await store.markWorkActive(marker(index: 0))

            let first = try await store.reconcileInterruptedWork()
            let afterFirst = try #require(
                defaults.data(forKey: UserDefaultsAgentContinuityStore.key))
            let second = try await store.reconcileInterruptedWork()

            #expect(first.map(\.state) == [.interruptedByProcessExit])
            #expect(second == first)
            #expect(defaults.data(forKey: UserDefaultsAgentContinuityStore.key) == afterFirst)
            #expect(try persistedEnvelope(defaults).interruptedWork == first)
        }
    }

    @Test func acknowledgeInterruptedWork_WhenMarkerMatches_RemovesOnlyInterruptedMarker()
        async throws
    {
        try await withStore { store, defaults in
            let interrupted = marker(index: 0)
            let active = marker(index: 1)
            try await store.markWorkActive(interrupted)
            _ = try await store.reconcileInterruptedWork()
            try await store.markWorkActive(active)

            try await store.acknowledgeInterruptedWork([interrupted.key, active.key])
            try await store.acknowledgeInterruptedWork([interrupted.key])

            #expect(try persistedEnvelope(defaults).interruptedWork == [active])
        }
    }

    @Test func clearWork_WhenTwoOccurrencesShareProviderTaskID_RemovesOnlyExactKey()
        async throws
    {
        try await withStore { store, defaults in
            let first = marker(index: 0, providerTaskID: "reused-task")
            let second = marker(index: 1, providerTaskID: "reused-task")
            try await store.markWorkActive(first)
            try await store.markWorkActive(second)

            try await store.clearWork(first.key)

            #expect(try persistedEnvelope(defaults).interruptedWork == [second])
        }
    }

    @Test func clearWork_WhenTwoPromptsAreActiveInOneProfile_PreservesOtherOccurrence()
        async throws
    {
        try await withStore { store, defaults in
            let first = marker(index: 0, profileIndex: 7, turnID: "turn-one")
            let second = marker(index: 1, profileIndex: 7, turnID: "turn-two")
            try await store.markWorkActive(first)
            try await store.markWorkActive(second)

            try await store.clearWork(first.key)

            #expect(try persistedEnvelope(defaults).interruptedWork == [second])
        }
    }

    @Test func remove_WhenGivenOneProfile_PreservesUnrelatedRecords() async throws {
        try await withStore { store, defaults in
            try await store.save(bookmark: bookmark(index: 0))
            try await store.save(bookmark: bookmark(index: 1))
            let first = marker(index: 0, profileIndex: 0)
            let second = marker(index: 1, profileIndex: 1)
            try await store.markWorkActive(first)
            try await store.markWorkActive(second)

            try await store.remove(profileIDs: [profileID(0)])

            let envelope = try persistedEnvelope(defaults)
            #expect(envelope.bookmarks.map(\.profileID) == [profileID(1)])
            #expect(envelope.interruptedWork == [second])
        }
    }

    @Test func markWorkActive_WhenSixtyFifthUniqueKeyIsAdded_ThrowsAtomically()
        async throws
    {
        try await withStore { store, defaults in
            for index in 0..<64 {
                try await store.markWorkActive(marker(index: index))
            }
            let before = defaults.data(forKey: UserDefaultsAgentContinuityStore.key)

            await expectThrow { try await store.markWorkActive(marker(index: 64)) }

            #expect(defaults.data(forKey: UserDefaultsAgentContinuityStore.key) == before)
            #expect(try persistedEnvelope(defaults).interruptedWork.count == 64)
        }
    }

    @Test func markWorkActive_WhenEncodedEnvelopeCrossesByteBound_ThrowsAtomically()
        async throws
    {
        try await withStore { store, defaults in
            let identifier = String(repeating: "a", count: 4_096)
            var observedFailure = false
            for index in 0..<64 {
                let before = defaults.data(forKey: UserDefaultsAgentContinuityStore.key)
                do {
                    try await store.markWorkActive(marker(
                        index: index,
                        sessionID: identifier,
                        turnID: identifier,
                        providerTaskID: identifier))
                } catch {
                    observedFailure = true
                    #expect(defaults.data(forKey: UserDefaultsAgentContinuityStore.key) == before)
                    break
                }
            }

            #expect(observedFailure)
        }
    }

    @Test func save_WhenAccessOrdinalWouldOverflow_RebasesInStableLRUOrder() async throws {
        try await withStore { store, defaults in
            let highID = profileID(1)
            let lowID = profileID(0)
            let envelope = AgentContinuityEnvelope(
                schemaVersion: 1,
                bookmarks: [
                    AgentSessionBookmark(
                        profileID: highID,
                        sessionID: "high",
                        providerFingerprint: fingerprint,
                        lastAccessOrdinal: .max),
                    AgentSessionBookmark(
                        profileID: lowID,
                        sessionID: "low",
                        providerFingerprint: fingerprint,
                        lastAccessOrdinal: .max),
                ],
                interruptedWork: [])
            defaults.set(try JSONEncoder().encode(envelope),
                forKey: UserDefaultsAgentContinuityStore.key)

            try await store.save(bookmark: bookmark(index: 2))

            let ordinals = Dictionary(uniqueKeysWithValues: try persistedEnvelope(defaults)
                .bookmarks.map { ($0.profileID, $0.lastAccessOrdinal) })
            #expect(ordinals[lowID] == 1)
            #expect(ordinals[highID] == 2)
            #expect(ordinals[profileID(2)] == 3)
        }
    }

    @Test func diagnostics_WhenStoreFails_ContainNoIdentifiersOrFingerprint() async throws {
        let diagnostics = AppDiagnosticRecorderSpy()
        try await withStore(diagnostics: diagnostics) { store, _ in
            await expectThrow {
                try await store.save(bookmark: bookmark(
                    index: 0,
                    sessionID: "private-session",
                    fingerprint: String(repeating: "F", count: 64)))
            }

            let entry = try #require(diagnostics.snapshot().last)
            #expect(entry.category == .settings)
            #expect(entry.event == "continuity_store.save_failed")
            #expect(entry.level == .error)
            #expect(Set(entry.fields.keys).isSubset(of: [
                "failure_category", "bookmark_count", "work_marker_count",
            ]))
            #expect(entry.fields["failure_category"] == "invalid_fingerprint")
            let rendered = String(describing: entry.fields)
            #expect(!rendered.contains("private-session"))
            #expect(!rendered.contains(String(repeating: "F", count: 64)))
        }
    }

    private let fingerprint = String(repeating: "a", count: 64)

    private func withStore(
        diagnostics: any YapOpsDiagnosticRecording = YapOpsDiagnostics.shared,
        operation: (UserDefaultsAgentContinuityStore, TestDefaults) async throws -> Void
    ) async throws {
        let suite = InMemoryDefaults.makeSuiteName("UserDefaultsAgentContinuityStoreTests")
        let defaults = TestDefaults(suite: suite)
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsAgentContinuityStore(
            defaults: try #require(InMemoryDefaults(suiteName: suite)),
            diagnostics: diagnostics)
        try await operation(store, defaults)
    }

    private func bookmark(
        index: Int,
        sessionID: String? = nil,
        fingerprint: String? = nil
    ) -> AgentSessionBookmark {
        AgentSessionBookmark(
            profileID: profileID(index),
            sessionID: sessionID ?? "session-\(index)",
            providerFingerprint: fingerprint ?? self.fingerprint,
            lastAccessOrdinal: 9_999)
    }

    private func marker(
        index: Int,
        profileIndex: Int? = nil,
        sessionID: String? = nil,
        turnID: String? = nil,
        providerTaskID: String? = nil,
        state: AgentInterruptedWorkState = .active
    ) -> AgentInterruptedWorkMarker {
        AgentInterruptedWorkMarker(
            key: AgentInterruptedWorkKey(
                profileID: profileID(profileIndex ?? index),
                sessionID: sessionID ?? "session-\(profileIndex ?? index)",
                occurrenceID: occurrenceID(index)),
            turnID: turnID,
            providerTaskID: providerTaskID,
            state: state)
    }

    private func workKey(index: Int) -> AgentInterruptedWorkKey {
        AgentInterruptedWorkKey(
            profileID: profileID(index),
            sessionID: "session-\(index)",
            occurrenceID: occurrenceID(index))
    }

    private func profileID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
    }

    private func occurrenceID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index + 1))!
    }

    private func persistedEnvelope(_ defaults: TestDefaults) throws -> AgentContinuityEnvelope {
        let data = try #require(defaults.data(forKey: UserDefaultsAgentContinuityStore.key))
        return try JSONDecoder().decode(AgentContinuityEnvelope.self, from: data)
    }

    private func expectThrow(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected operation to throw")
        } catch {}
    }

    private struct TestDefaults: Sendable {
        let suite: String

        func data(forKey key: String) -> Data? {
            InMemoryDefaults(suiteName: suite)?.data(forKey: key)
        }

        func set(_ value: Data, forKey key: String) {
            InMemoryDefaults(suiteName: suite)?.set(value, forKey: key)
        }

        func removePersistentDomain(forName name: String) {
            InMemoryDefaults(suiteName: suite)?.removePersistentDomain(forName: name)
        }
    }
}

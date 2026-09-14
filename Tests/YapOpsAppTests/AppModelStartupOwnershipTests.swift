// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Observation
import Testing

@testable import YapOpsApp
@testable import YapOpsCore

extension AppModelTests {
    @MainActor @Test
    func startup_WhenReady_NotifiesSettingsReadinessObservers() async throws {
        let composition = try startupComposition()
        let probe = StartupReadinessObservationProbe()
        withObservationTracking {
            _ = composition.model.isStartupReady
        } onChange: {
            probe.markChanged()
        }

        #expect(await composition.startup.run())
        #expect(probe.wasChanged)
    }

    @MainActor @Test
    func startup_WhenCancelledDuringReconciliation_ReplacementOwnsReadyState() async throws {
        let store = StartupReconciliationGateStore()
        let credentials = StartupCredentialGate()
        let access = MacContextAccessSpy(status: .authorized)
        let composition = try startupComposition(
            continuityStore: store,
            credentials: credentials,
            access: access)
        let first = Task { @MainActor in await composition.startup.run() }
        await store.waitUntilFirstCallEntered()

        composition.startup.cancel()
        await store.allowFutureCalls()
        let replacement = Task { @MainActor in await composition.startup.run() }
        await credentials.waitUntilLoadEntered(1)
        await store.releaseFirstCall()

        #expect(!(await first.value))
        #expect(!composition.model.isStartupReady)
        credentials.resolveLoad(1, returning: "replacement-key")
        #expect(await replacement.value)
        #expect(composition.model.isStartupReady)
        #expect(await store.callCount == 2)
        #expect(access.statusChecks == 1)
    }

    @MainActor @Test
    func startup_WhenCancelledDuringCredentialLoad_ReplacementRejectsLateCredential() async throws {
        let credentials = StartupCredentialGate()
        let diagnostics = AppDiagnosticRecorderSpy()
        let composition = try startupComposition(
            credentials: credentials,
            diagnostics: diagnostics)
        let first = Task { @MainActor in await composition.startup.run() }
        await credentials.waitUntilLoadEntered(1)

        composition.startup.cancel()
        let replacement = Task { @MainActor in await composition.startup.run() }
        await credentials.waitUntilLoadEntered(2)
        credentials.resolveLoad(1, returning: "stale-key")

        #expect(!(await first.value))
        #expect(composition.model.elevenLabsAPIKey.isEmpty)
        #expect(!composition.model.isStartupReady)
        #expect(diagnostics.snapshot().allSatisfy { $0.event != "credential_load.finished" })
        credentials.resolveLoad(2, returning: "replacement-key")
        #expect(await replacement.value)
        #expect(credentials.loadCount == 2)
        #expect(composition.model.elevenLabsAPIKey == "replacement-key")
        #expect(composition.model.isStartupReady)
        #expect(diagnostics.snapshot().count { $0.event == "credential_load.finished" } == 1)
        #expect(diagnostics.snapshot().count { $0.event == "app_model.start_finished" } == 1)
    }

    @MainActor @Test
    func startup_WhenCancelledDuringPermission_ReplacementAloneStartsListening() async throws {
        let permissions = StartupPermissionGate()
        let speech = AppModelSpeechSessionSpy()
        let diagnostics = AppDiagnosticRecorderSpy()
        let composition = try startupComposition(
            permissionRequest: { await permissions.request() },
            speech: speech,
            diagnostics: diagnostics)
        let first = Task { @MainActor in await composition.startup.run() }
        await permissions.waitUntilRequestEntered(1)

        composition.startup.cancel()
        let replacement = Task { @MainActor in await composition.startup.run() }
        await permissions.waitUntilRequestEntered(2)
        permissions.resolveRequest(1, returning: true)

        #expect(!(await first.value))
        #expect(speech.startCount == 0)
        #expect(!composition.model.isStartupReady)
        #expect(diagnostics.snapshot().allSatisfy { $0.event != "permissions.request_finished" })
        permissions.resolveRequest(2, returning: true)
        #expect(await replacement.value)
        #expect(permissions.requestCount == 2)
        #expect(speech.startCount == 1)
        #expect(composition.model.isStartupReady)
        #expect(diagnostics.snapshot().count { $0.event == "permissions.request_finished" } == 1)
        #expect(diagnostics.snapshot().count { $0.event == "app_model.start_finished" } == 1)
    }

    @MainActor @Test
    func startup_WhenCancelledBeforeMonitorArm_DoesNotInstallLateObserver() async throws {
        let notificationCenter = NotificationCenter()
        let access = MacContextAccessSpy(status: .authorized)
        let armGate = StartupMonitorArmGate()
        let composition = try startupComposition(
            access: access,
            notificationCenter: notificationCenter,
            beforeMonitorArm: { await armGate.wait() })
        let first = Task { @MainActor in await composition.startup.run() }
        await armGate.waitUntilCallEntered(1)

        composition.startup.cancel()
        let replacement = Task { @MainActor in await composition.startup.run() }
        await armGate.waitUntilCallEntered(2)
        await armGate.resolveCall(1)
        #expect(!(await first.value))
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(access.statusChecks == 1)

        await armGate.resolveCall(2)
        #expect(await replacement.value)
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(access.statusChecks == 2)
    }

    @MainActor
    private func startupComposition(
        continuityStore: any AgentContinuityStoring = InMemoryAgentContinuityStore(),
        credentials: any AgentSpeechCredentialStoring = AgentSpeechCredentialStoreSpy(),
        access: MacContextAccessSpy = MacContextAccessSpy(),
        permissionRequest: @escaping @MainActor () async -> Bool = { true },
        speech: AppModelSpeechSessionSpy = AppModelSpeechSessionSpy(),
        notificationCenter: NotificationCenter = NotificationCenter(),
        beforeMonitorArm: @escaping @MainActor @Sendable () async -> Void = {},
        diagnostics: any YapOpsDiagnosticRecording = YapOpsDiagnostics.shared
    ) throws -> YapOpsAppComposition {
        let suite = InMemoryDefaults.makeSuiteName("YapOpsStartupOwnershipTests")
        let defaults = try #require(InMemoryDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        return YapOpsAppComposition.make(
            continuityStore: continuityStore,
            activationMonitor: ApplicationActivationMonitor(
                notificationCenter: notificationCenter),
            beforeMonitorArm: beforeMonitorArm,
            makeAgentRunner: { _ in AppModelAgentRunnerSpy() },
            makeModel: { runner, sharedStore in
                AppModel(
                    preferences: preferences,
                    recordingOverlay: AppModelOverlayStub(),
                    agentRunPanel: AppModelAgentPanelSpy(),
                    shortcut: ShortcutSpy(),
                    speechSession: speech,
                    agentRunner: runner,
                    continuityStore: sharedStore,
                    permissionRequest: permissionRequest,
                    soundPlayer: SilentCaptureSoundPlayer(),
                    agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
                    agentSpeechCredentialStore: credentials,
                    elevenLabsVoiceCatalog: AppModelElevenLabsVoiceCatalogSpy(voices: []),
                    textToSpeechVoicePreview: AppModelTextToSpeechVoicePreviewSpy(),
                    macContextAccess: access,
                    macContextCapturer: MacContextCapturerSpy(),
                    isExecutableFile: { _ in true },
                    isDirectory: { _ in true },
                    startsAutomatically: false,
                    diagnostics: diagnostics)
            })
    }
}

private final class StartupReadinessObservationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false

    var wasChanged: Bool { lock.withLock { changed } }

    func markChanged() {
        lock.withLock { changed = true }
    }
}

private actor StartupReconciliationGateStore: AgentContinuityStoring {
    private var calls = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var firstWaiters: [CheckedContinuation<Void, Never>] = []
    private var futureCallsAllowed = false

    var callCount: Int { calls }

    func bookmark(for profileID: UUID) async throws -> AgentSessionBookmark? { nil }
    func save(bookmark: AgentSessionBookmark) async throws {}
    func remove(profileIDs: Set<UUID>) async throws {}
    func markWorkActive(_ marker: AgentInterruptedWorkMarker) async throws {}
    func clearWork(_ key: AgentInterruptedWorkKey) async throws {}
    func acknowledgeInterruptedWork(_ keys: Set<AgentInterruptedWorkKey>) async throws {}

    func reconcileInterruptedWork() async throws -> [AgentInterruptedWorkMarker] {
        calls += 1
        guard calls == 1, !futureCallsAllowed else { return [] }
        let waiters = firstWaiters
        firstWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { firstContinuation = $0 }
        return []
    }

    func waitUntilFirstCallEntered() async {
        guard firstContinuation == nil else { return }
        await withCheckedContinuation { firstWaiters.append($0) }
    }

    func allowFutureCalls() { futureCallsAllowed = true }

    func releaseFirstCall() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

@MainActor
private final class StartupCredentialGate: AgentSpeechCredentialStoring {
    private var continuations: [Int: CheckedContinuation<String?, Never>] = [:]
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var resolvedValues: [Int: String] = [:]
    private(set) var loadCount = 0

    func loadElevenLabsAPIKey() async throws -> String? {
        loadCount += 1
        let call = loadCount
        if let value = resolvedValues.removeValue(forKey: call) { return value }
        let callWaiters = waiters.removeValue(forKey: call) ?? []
        callWaiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuations[call] = $0 }
    }

    func saveElevenLabsAPIKey(_ apiKey: String?) throws {}

    func waitUntilLoadEntered(_ call: Int) async {
        guard loadCount < call else { return }
        await withCheckedContinuation { waiters[call, default: []].append($0) }
    }

    func resolveLoad(_ call: Int, returning value: String) {
        guard let continuation = continuations.removeValue(forKey: call) else {
            resolvedValues[call] = value
            return
        }
        continuation.resume(returning: value)
    }
}

@MainActor
private final class StartupPermissionGate {
    private var continuations: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var resolvedValues: [Int: Bool] = [:]
    private(set) var requestCount = 0

    func request() async -> Bool {
        requestCount += 1
        let call = requestCount
        if let value = resolvedValues.removeValue(forKey: call) { return value }
        let callWaiters = waiters.removeValue(forKey: call) ?? []
        callWaiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuations[call] = $0 }
    }

    func waitUntilRequestEntered(_ call: Int) async {
        guard requestCount < call else { return }
        await withCheckedContinuation { waiters[call, default: []].append($0) }
    }

    func resolveRequest(_ call: Int, returning value: Bool) {
        guard let continuation = continuations.removeValue(forKey: call) else {
            resolvedValues[call] = value
            return
        }
        continuation.resume(returning: value)
    }
}

private actor StartupMonitorArmGate {
    private var callCount = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var resolvedCalls: Set<Int> = []

    func wait() async {
        callCount += 1
        let call = callCount
        if resolvedCalls.remove(call) != nil { return }
        let callWaiters = waiters.removeValue(forKey: call) ?? []
        callWaiters.forEach { $0.resume() }
        await withCheckedContinuation { continuations[call] = $0 }
    }

    func waitUntilCallEntered(_ call: Int) async {
        guard callCount < call else { return }
        await withCheckedContinuation { waiters[call, default: []].append($0) }
    }

    func resolveCall(_ call: Int) {
        guard let continuation = continuations.removeValue(forKey: call) else {
            resolvedCalls.insert(call)
            return
        }
        continuation.resume()
    }
}

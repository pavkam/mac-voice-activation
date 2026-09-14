// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import YapOpsApp
@testable import YapOpsCore


extension AppModelTests {
    @MainActor
    func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        if !(await condition()) {
            Issue.record("Condition was not satisfied before timeout")
        }
    }

    @MainActor
    struct Fixture {
        let preferences: AppPreferences
        let shortcut = ShortcutSpy()
        let speech = AppModelSpeechSessionSpy()
        let agentRunPanel: AppModelAgentPanelSpy
        let actionFeedback = RecordingActionFeedbackDisplay()
        let macContextAccess: MacContextAccessSpy
        let macContextCapturer: MacContextCapturerSpy
        let model: AppModel

        init(
            profiles: [WakeProfile]? = nil,
            agentRunner: any AgentHarnessRunning = AppModelAgentRunnerSpy(),
            continuityStore: any AgentContinuityStoring = InMemoryAgentContinuityStore(),
            agentRunPanel: AppModelAgentPanelSpy = AppModelAgentPanelSpy(),
            agentConversationAudioPlayer: any AgentConversationAudioPlaying =
                SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: any AgentSpeechCredentialStoring =
                AgentSpeechCredentialStoreSpy(),
            elevenLabsVoiceCatalog: any ElevenLabsVoiceCatalogLoading =
                AppModelElevenLabsVoiceCatalogSpy(voices: []),
            textToSpeechVoicePreview: any TextToSpeechVoicePreviewing =
                AppModelTextToSpeechVoicePreviewSpy(),
            textToSpeechBackendRegistry: TextToSpeechBackendRegistry? = nil,
            macContextAccess: MacContextAccessSpy = MacContextAccessSpy(),
            macContextCapturer: MacContextCapturerSpy = MacContextCapturerSpy(),
            permissionRequest: @escaping @MainActor () async -> Bool = { true },
            isExecutableFile: @escaping @MainActor (String) -> Bool = { path in
                FileManager.default.isExecutableFile(atPath: path)
            },
            isDirectory: @escaping @MainActor (String) -> Bool = { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            },
            agentSessionEventScheduler: any AgentSessionEventScheduling =
                MainRunLoopAgentSessionEventScheduler(),
            diagnostics: any YapOpsDiagnosticRecording =
                YapOpsDiagnostics.shared
        ) throws {
            let suite = InMemoryDefaults.makeSuiteName("YapOpsAppModelTests")
            let defaults = try #require(InMemoryDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            preferences = AppPreferences(defaults: defaults)
            self.agentRunPanel = agentRunPanel
            self.macContextAccess = macContextAccess
            self.macContextCapturer = macContextCapturer
            if let profiles {
                preferences.wakeProfiles = profiles
            }
            model = AppModel(
                preferences: preferences,
                recordingOverlay: AppModelOverlayStub(),
                actionFeedback: actionFeedback,
                agentRunPanel: agentRunPanel,
                shortcut: shortcut,
                speechSession: speech,
                agentRunner: agentRunner,
                continuityStore: continuityStore,
                permissionRequest: permissionRequest,
                soundPlayer: SilentCaptureSoundPlayer(),
                agentConversationAudioPlayer: agentConversationAudioPlayer,
                agentSpeechCredentialStore: agentSpeechCredentialStore,
                elevenLabsVoiceCatalog: elevenLabsVoiceCatalog,
                textToSpeechVoicePreview: textToSpeechVoicePreview,
                textToSpeechBackendRegistry: textToSpeechBackendRegistry,
                macContextAccess: macContextAccess,
                macContextCapturer: macContextCapturer,
                isExecutableFile: isExecutableFile,
                isDirectory: isDirectory,
                agentSessionEventScheduler: agentSessionEventScheduler,
                startsAutomatically: false,
                diagnostics: diagnostics)
        }

        func startForExternalActions() async {
            #expect(await model.start())
            shortcut.resetObservations()
            macContextAccess.resetObservations()
        }
    }

    func makeAgentProfile(
        id: UUID = UUID(),
        displayName: String = "Custom agent",
        executablePath: String = "/agents/custom",
        workingDirectory: String = "/Users/test/project",
        pushToTalkHotKey: PushToTalkHotKey? = nil
    ) throws -> WakeProfile {
        let configuration = try AgentHarnessConfiguration(
            preset: .custom,
            displayName: displayName,
            executablePath: executablePath,
            arguments: ["--stdio", "two words"],
            workingDirectory: workingDirectory,
            permissionPolicy: .ask)
        return try WakeProfile(
            id: id,
            wakePhrase: displayName,
            action: .agent(configuration),
            accent: .purple,
            pushToTalkHotKey: pushToTalkHotKey)
    }
}

actor AppModelContinuityStoreSpy: AgentContinuityStoring {
    enum Call: Equatable, Sendable {
        case bookmark(UUID)
        case save(UUID)
        case remove(Set<UUID>)
        case mark(AgentInterruptedWorkKey)
        case clear(AgentInterruptedWorkKey)
        case reconcile
        case acknowledge(Set<AgentInterruptedWorkKey>)
    }

    enum Failure: Error {
        case reconciliation
        case removal
    }

    private var envelope: AgentContinuityEnvelope
    private var calls: [Call] = []
    private var reconcileContinuation: CheckedContinuation<Void, Never>?
    private var reconcileWaiters: [CheckedContinuation<Void, Never>] = []
    private var delaysReconciliation = false
    private var failsReconciliation = false
    private var failsRemoval = false
    private var reconciledOverride: [AgentInterruptedWorkMarker]?

    init(
        bookmarks: [AgentSessionBookmark] = [],
        markers: [AgentInterruptedWorkMarker] = [],
        reconciledOverride: [AgentInterruptedWorkMarker]? = nil
    ) {
        envelope = AgentContinuityEnvelope(
            schemaVersion: AgentContinuityStorePolicy.schemaVersion,
            bookmarks: bookmarks,
            interruptedWork: markers)
        self.reconciledOverride = reconciledOverride
    }

    func bookmark(for profileID: UUID) async throws -> AgentSessionBookmark? {
        calls.append(.bookmark(profileID))
        return try AgentContinuityStorePolicy.bookmark(for: profileID, in: &envelope)
    }

    func save(bookmark: AgentSessionBookmark) async throws {
        calls.append(.save(bookmark.profileID))
        try AgentContinuityStorePolicy.save(bookmark, in: &envelope)
    }

    func remove(profileIDs: Set<UUID>) async throws {
        calls.append(.remove(profileIDs))
        if failsRemoval { throw Failure.removal }
        try AgentContinuityStorePolicy.remove(profileIDs: profileIDs, in: &envelope)
    }

    func markWorkActive(_ marker: AgentInterruptedWorkMarker) async throws {
        calls.append(.mark(marker.key))
        try AgentContinuityStorePolicy.markWorkActive(marker, in: &envelope)
    }

    func clearWork(_ key: AgentInterruptedWorkKey) async throws {
        calls.append(.clear(key))
        try AgentContinuityStorePolicy.clearWork(key, in: &envelope)
    }

    func reconcileInterruptedWork() async throws -> [AgentInterruptedWorkMarker] {
        calls.append(.reconcile)
        if delaysReconciliation {
            await withCheckedContinuation { continuation in
                reconcileContinuation = continuation
                let waiters = reconcileWaiters
                reconcileWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        if failsReconciliation { throw Failure.reconciliation }
        if let reconciledOverride { return reconciledOverride }
        return try AgentContinuityStorePolicy.reconcileInterruptedWork(in: &envelope)
    }

    func acknowledgeInterruptedWork(_ keys: Set<AgentInterruptedWorkKey>) async throws {
        calls.append(.acknowledge(keys))
        try AgentContinuityStorePolicy.acknowledgeInterruptedWork(keys, in: &envelope)
    }

    func delayReconciliation() { delaysReconciliation = true }
    func failReconciliation() { failsReconciliation = true }
    func failRemoval() { failsRemoval = true }

    func waitUntilReconciling() async {
        guard reconcileContinuation == nil else { return }
        await withCheckedContinuation { reconcileWaiters.append($0) }
    }

    func releaseReconciliation() {
        delaysReconciliation = false
        reconcileContinuation?.resume()
        reconcileContinuation = nil
    }

    func recordedCalls() -> [Call] { calls }
    func snapshot() -> AgentContinuityEnvelope { envelope }
}

@MainActor
final class MacContextAccessSpy: MacContextAccessControlling {
    var status: MacContextAccessStatus
    var statusChecks = 0
    var promptingChecks = 0
    var statusAfterPrompt: MacContextAccessStatus?

    init(status: MacContextAccessStatus = .notAuthorized) {
        self.status = status
    }

    func currentStatus() -> MacContextAccessStatus {
        statusChecks += 1
        return status
    }

    func requestMacContextAccess() {
        promptingChecks += 1
        if let statusAfterPrompt {
            status = statusAfterPrompt
        }
    }

    func resetObservations() {
        statusChecks = 0
        promptingChecks = 0
    }
}

@MainActor
final class MacContextCapturerSpy: MacContextCapturing {
    var target: MacContextTarget?
    var snapshot: MacContextSnapshot?
    var currentTargetCount = 0
    var captureCount = 0
    private(set) var captureCancellationCount = 0
    private var delaysCapture = false
    private var captureContinuation: CheckedContinuation<MacContextSnapshot, Never>?
    private var delayedResult: MacContextSnapshot?
    private var captureWaiters: [CheckedContinuation<Void, Never>] = []

    init(target: MacContextTarget? = nil, snapshot: MacContextSnapshot? = nil) {
        self.target = target
        self.snapshot = snapshot
    }

    func currentTarget() -> MacContextTarget? {
        currentTargetCount += 1
        return target
    }

    func capture(_ target: MacContextTarget) async -> MacContextSnapshot {
        captureCount += 1
        let result = snapshot ?? MacContextSnapshot.normalized(
            state: .targetUnavailable,
            target: target,
            windowTitle: nil,
            documentURL: nil,
            selectedText: nil,
            resources: [])
        let waiters = captureWaiters
        captureWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard delaysCapture else { return result }
        delayedResult = result
        return await withTaskCancellationHandler {
            await withCheckedContinuation { captureContinuation = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.captureCancellationCount += 1
                self.releaseCapture(returning: result)
            }
        }
    }

    func delayCapture() { delaysCapture = true }

    func waitUntilCapturing() async {
        guard captureCount == 0 else { return }
        await withCheckedContinuation { captureWaiters.append($0) }
    }

    func releaseCapture(returning result: MacContextSnapshot? = nil) {
        delaysCapture = false
        guard let continuation = captureContinuation else { return }
        captureContinuation = nil
        guard let resumedResult = result ?? delayedResult else {
            preconditionFailure("A delayed capture must retain its result")
        }
        delayedResult = nil
        continuation.resume(returning: resumedResult)
    }
}

@MainActor
final class MacContextAccessNativeSpy: MacContextAccessNativeChecking {
    var isTrusted: Bool
    var statusChecks = 0
    var promptingChecks = 0

    init(isTrusted: Bool) {
        self.isTrusted = isTrusted
    }

    func isProcessTrusted() -> Bool {
        statusChecks += 1
        return isTrusted
    }

    func requestProcessTrust() {
        promptingChecks += 1
    }
}

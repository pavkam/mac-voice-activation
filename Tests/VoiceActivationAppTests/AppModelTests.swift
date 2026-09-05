// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import VoiceActivationApp
@testable import VoiceActivationCore

@MainActor
final class ShortcutSpy: PushToTalkShortcutManaging {
    private(set) var startedProfiles: [[WakeProfile]] = []
    private(set) var registeredProfiles: [WakeProfile] = []
    private(set) var stopCount = 0
    private var onPressed: ((UUID) -> Void)?
    private var onReleased: ((UUID) -> Void)?
    var failNextStart = false

    func start(
        profiles: [WakeProfile],
        onPressed: @escaping (UUID) -> Void,
        onReleased: @escaping (UUID) -> Void
    ) throws {
        startedProfiles.append(profiles)
        if failNextStart {
            failNextStart = false
            throw ShortcutSpyError.registrationFailed
        }
        registeredProfiles = profiles
        self.onPressed = onPressed
        self.onReleased = onReleased
    }

    func stop() {
        stopCount += 1
    }

    func press(_ profileID: UUID) {
        onPressed?(profileID)
    }

    func release(_ profileID: UUID) {
        onReleased?(profileID)
    }
}

enum ShortcutSpyError: Error, LocalizedError {
    case registrationFailed

    var errorDescription: String? { "Shortcut registration failed." }
}

@MainActor
final class AppModelOverlayStub: RecordingOverlayDisplaying {
    var onCancel: (() -> Void)?
    private(set) var shownAccents: [WakeProfileAccent] = []

    func show(transcript: String, accent: WakeProfileAccent) {
        shownAccents.append(accent)
    }
    func hide() {}
}

@MainActor
final class AppModelAgentPanelSpy: AgentRunPanelDisplaying {
    var onAction: ((AgentRunPanelAction) -> Void)?
    private(set) var began: [AgentRunSnapshot] = []
    private(set) var updates: [AgentRunSnapshot] = []
    private(set) var shown: [UUID] = []
    private(set) var hidden: [UUID] = []

    func begin(_ snapshot: AgentRunSnapshot, from handoff: RecordingOverlayHandoff?) {
        began.append(snapshot)
    }

    func update(_ snapshot: AgentRunSnapshot) { updates.append(snapshot) }
    func show(runID: UUID) { shown.append(runID) }
    func hide(runID: UUID) { hidden.append(runID) }
    func minimize(runID: UUID) {}
    func restore(runID: UUID) {}
}

@MainActor
final class AppModelSpeechSessionSpy: SpeechSessionProtocol {
    private(set) var startCount = 0
    private(set) var mode: SpeechSessionMode?
    private var onUpdate: ((SpeechUpdate) -> Void)?

    func start(
        mode: SpeechSessionMode,
        localeID: String,
        contextualStrings: [String],
        onUpdate: @escaping (SpeechUpdate) -> Void,
        onInterruption: @escaping () -> Void
    ) throws {
        startCount += 1
        self.mode = mode
        self.onUpdate = onUpdate
    }

    func stop() {
        mode = nil
        onUpdate = nil
    }

    func emit(_ transcript: String, isFinal: Bool = false) {
        onUpdate?(
            SpeechUpdate(
                transcript: transcript,
                isFinal: isFinal,
                errorDescription: nil))
    }
}

actor AppModelAgentRunnerSpy: AgentHarnessRunning {
    struct Invocation: Equatable, Sendable {
        let profileID: UUID
        let configuration: AgentHarnessConfiguration
        let prompt: String
    }

    private var invocations: [Invocation] = []
    private var resets: [Set<UUID>] = []
    private var shouldDelayReset = false
    private var resetContinuation: CheckedContinuation<Void, Never>?
    private let events: [AgentRunEvent]

    init(events: [AgentRunEvent] = []) {
        self.events = events
    }

    func run(
        profileID: UUID,
        configuration: AgentHarnessConfiguration,
        prompt: String,
        onEvent: @escaping @Sendable (AgentRunEvent) async -> Void
    ) async throws -> AgentRunResult {
        invocations.append(
            Invocation(
                profileID: profileID,
                configuration: configuration,
                prompt: prompt))
        for event in events {
            await onEvent(event)
        }
        return AgentRunResult(stopReason: .endTurn)
    }

    func resolvePermission(
        turnToken: AgentTurnToken,
        requestID: ACPRequestID,
        optionID: String?
    ) async {}

    func cancel() async {}

    func reset(profileIDs: Set<UUID>) async {
        resets.append(profileIDs)
        guard shouldDelayReset else { return }
        await withCheckedContinuation { resetContinuation = $0 }
    }

    func shutdown() async {}

    func recordedInvocations() -> [Invocation] { invocations }
    func recordedResets() -> [Set<UUID>] { resets }
    func delayReset() { shouldDelayReset = true }
    func resetIsWaiting() -> Bool { resetContinuation != nil }
    func releaseReset() {
        shouldDelayReset = false
        resetContinuation?.resume()
        resetContinuation = nil
    }
}

actor AppModelPermissionAgentRunnerSpy: AgentHarnessRunning {
    struct Resolution: Equatable, Sendable {
        let turnToken: AgentTurnToken
        let requestID: ACPRequestID
        let optionID: String?
    }

    let turnToken = AgentTurnToken()
    let requestID = ACPRequestID.string("voice-permission")
    private var resolutions: [Resolution] = []
    private var continuation: CheckedContinuation<AgentRunResult, Never>?

    func run(
        profileID: UUID,
        configuration: AgentHarnessConfiguration,
        prompt: String,
        onEvent: @escaping @Sendable (AgentRunEvent) async -> Void
    ) async throws -> AgentRunResult {
        await onEvent(
            .permissionRequested(
                AgentPermissionRequest(
                    turnToken: turnToken,
                    requestID: requestID,
                    toolCall: AgentToolCallUpdate(
                        id: "tool-1",
                        title: "Edit settings",
                        kind: .edit,
                        status: .pending),
                    options: [
                        AgentPermissionOption(
                            id: "allow-once",
                            label: "Allow once",
                            kind: .allowOnce),
                        AgentPermissionOption(
                            id: "allow-always",
                            label: "Allow always",
                            kind: .allowAlways),
                        AgentPermissionOption(
                            id: "deny-once",
                            label: "Deny",
                            kind: .rejectOnce),
                    ])))
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolvePermission(
        turnToken: AgentTurnToken,
        requestID: ACPRequestID,
        optionID: String?
    ) async {
        resolutions.append(
            Resolution(
                turnToken: turnToken,
                requestID: requestID,
                optionID: optionID))
        continuation?.resume(returning: AgentRunResult(stopReason: .endTurn))
        continuation = nil
    }

    func cancel() async {
        continuation?.resume(returning: AgentRunResult(stopReason: .cancelled))
        continuation = nil
    }

    func reset(profileIDs: Set<UUID>) async {}
    func shutdown() async {}

    func recordedResolutions() -> [Resolution] {
        resolutions
    }
}

@MainActor
final class AppModelAgentConversationAudioSpy: AgentConversationAudioPlaying {
    var onSpeakingChange: ((Bool) -> Void)?
    private(set) var spoken: [(text: String, localeID: String)] = []

    func setWorking(_ working: Bool) {}
    func playActivitySound(_ sound: AgentActivitySound) {}

    func speak(_ text: String, localeID: String) {
        spoken.append((text, localeID))
        onSpeakingChange?(true)
    }

    func stopSpeaking() {
        onSpeakingChange?(false)
    }

    func stopAll() {
        onSpeakingChange?(false)
    }
}

@MainActor
final class AgentSpeechCredentialStoreSpy: AgentSpeechCredentialStoring {
    private(set) var apiKey: String?
    private(set) var loadCount = 0
    private(set) var savedKeys: [String?] = []

    init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    func loadElevenLabsAPIKey() async throws -> String? {
        loadCount += 1
        return apiKey
    }

    func saveElevenLabsAPIKey(_ apiKey: String?) throws {
        self.apiKey = apiKey
        savedKeys.append(apiKey)
    }
}

actor AppModelElevenLabsVoiceCatalogSpy: ElevenLabsVoiceCatalogLoading {
    private let availableVoices: [ElevenLabsVoice]
    private(set) var requestedAPIKeys: [String] = []

    init(voices: [ElevenLabsVoice]) {
        availableVoices = voices
    }

    func voices(apiKey: String) async throws -> [ElevenLabsVoice] {
        requestedAPIKeys.append(apiKey)
        return availableVoices
    }
}

@MainActor
final class AppModelElevenLabsVoicePreviewSpy: ElevenLabsVoicePreviewing {
    private(set) var requests: [(apiKey: String, voiceID: String)] = []
    private(set) var stopCount = 0

    func play(apiKey: String, voiceID: String) async throws {
        requests.append((apiKey, voiceID))
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
final class PermissionRequestGate {
    private var continuations: [CheckedContinuation<Bool, Never>] = []
    private(set) var requestCount = 0
    private(set) var completionCount = 0
    var isWaiting: Bool { !continuations.isEmpty }

    func request() async -> Bool {
        requestCount += 1
        let granted = await withCheckedContinuation { continuations.append($0) }
        completionCount += 1
        return granted
    }

    func resolve(_ granted: Bool) {
        let pending = continuations
        continuations = []
        for continuation in pending {
            continuation.resume(returning: granted)
        }
    }
}

@MainActor
final class PermissionPriorityRecorder {
    private(set) var priorities: [TaskPriority] = []

    func recordCurrentPriority() {
        priorities.append(Task.currentPriority)
    }
}

struct AppModelTests {
}

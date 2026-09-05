// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore

final class ConversationStartGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() {
        semaphore.wait()
    }

    func release() {
        semaphore.signal()
    }
}

@MainActor
final class FakeSpeechSession: SpeechSessionProtocol {
    private(set) var mode: SpeechSessionMode?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var contextualStrings: [String] = []
    private var handler: ((SpeechUpdate) -> Void)?
    private var interruptionHandler: (() -> Void)?
    private var retiredHandlers: [(SpeechUpdate) -> Void] = []
    private var failingMode: SpeechSessionMode?
    private var conversationStartGate: ConversationStartGate?

    func start(
        mode: SpeechSessionMode,
        localeID: String,
        contextualStrings: [String],
        onUpdate: @escaping (SpeechUpdate) -> Void,
        onInterruption: @escaping () -> Void) throws
    {
        if failingMode == mode {
            failingMode = nil
            throw FakeSpeechSessionError.startFailed
        }
        startCount += 1
        self.mode = mode
        self.contextualStrings = contextualStrings
        handler = onUpdate
        interruptionHandler = onInterruption
        if mode == .conversation, let conversationStartGate {
            self.conversationStartGate = nil
            conversationStartGate.wait()
        }
    }

    func stop() {
        stopCount += 1
        mode = nil
        if let handler {
            retiredHandlers.append(handler)
        }
        handler = nil
        interruptionHandler = nil
    }

    func emit(_ transcript: String, isFinal: Bool = false) {
        handler?(SpeechUpdate(transcript: transcript, isFinal: isFinal, errorDescription: nil))
    }

    func emitError(_ description: String) {
        handler?(SpeechUpdate(transcript: "", isFinal: false, errorDescription: description))
    }

    func interrupt() {
        interruptionHandler?()
    }

    func emitFromRetiredSession(_ transcript: String, isFinal: Bool = false) {
        retiredHandlers.last?(
            SpeechUpdate(transcript: transcript, isFinal: isFinal, errorDescription: nil))
    }

    func failNextStart(for mode: SpeechSessionMode) {
        failingMode = mode
    }

    func blockNextConversationStart(using gate: ConversationStartGate) {
        conversationStartGate = gate
    }
}

enum FakeSpeechSessionError: Error {
    case startFailed
}

actor RecordingCommandRunner: CommandRunning {
    private(set) var transcripts: [String] = []
    private(set) var templates: [CommandTemplate] = []

    func run(template: CommandTemplate, transcript: String) async throws -> CommandResult {
        templates.append(template)
        transcripts.append(transcript)
        return CommandResult(terminationStatus: 0)
    }

    func recordedTranscripts() -> [String] {
        transcripts
    }

    func recordedTemplates() -> [CommandTemplate] {
        templates
    }
}

actor ControlledCommandRunner: CommandRunning {
    private var transcripts: [String] = []
    private var continuations: [CheckedContinuation<CommandResult, Never>] = []

    func run(template: CommandTemplate, transcript: String) async throws -> CommandResult {
        transcripts.append(transcript)
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func recordedTranscripts() -> [String] {
        transcripts
    }

    func completeNext() {
        continuations.removeFirst().resume(returning: CommandResult(terminationStatus: 0))
    }
}

actor ControlledAgentRunner: AgentHarnessRunning {
    struct Invocation: Equatable, Sendable {
        let profileID: UUID
        let configuration: AgentHarnessConfiguration
        let prompt: String
    }

    struct PermissionResolution: Equatable, Sendable {
        let turnToken: AgentTurnToken
        let requestID: ACPRequestID
        let optionID: String?
    }

    private(set) var cancelCount = 0
    private(set) var shutdownCount = 0
    private var invocations: [Invocation] = []
    private var permissionResolutions: [PermissionResolution] = []
    private var eventHandlers: [@Sendable (AgentRunEvent) async -> Void] = []
    private var completions: [CheckedContinuation<AgentRunResult, any Error>?] = []
    private var activeRunIndex: Int?
    private var delaysCancellation = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func run(
        profileID: UUID,
        configuration: AgentHarnessConfiguration,
        prompt: String,
        onEvent: @escaping @Sendable (AgentRunEvent) async -> Void
    ) async throws -> AgentRunResult {
        guard activeRunIndex == nil else {
            throw ControlledAgentRunnerError.turnAlreadyActive
        }

        let runIndex = invocations.count
        invocations.append(Invocation(
            profileID: profileID,
            configuration: configuration,
            prompt: prompt))
        eventHandlers.append(onEvent)
        activeRunIndex = runIndex
        return try await withCheckedThrowingContinuation { continuation in
            completions.append(continuation)
        }
    }

    func resolvePermission(
        turnToken: AgentTurnToken,
        requestID: ACPRequestID,
        optionID: String?) async
    {
        permissionResolutions.append(PermissionResolution(
            turnToken: turnToken,
            requestID: requestID,
            optionID: optionID))
    }

    func cancel() async {
        cancelCount += 1
        if delaysCancellation {
            await withCheckedContinuation { continuation in
                cancellationWaiters.append(continuation)
            }
        }
        activeRunIndex = nil
    }

    func reset(profileIDs: Set<UUID>) async {}

    func shutdown() async {
        shutdownCount += 1
        activeRunIndex = nil
    }

    func recordedInvocations() -> [Invocation] {
        invocations
    }

    func recordedPermissionResolutions() -> [PermissionResolution] {
        permissionResolutions
    }

    func delayCancellation() {
        delaysCancellation = true
    }

    func releaseCancellation() {
        delaysCancellation = false
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func emit(_ event: AgentRunEvent, from runIndex: Int) async {
        await eventHandlers[runIndex](event)
    }

    func complete(
        runIndex: Int,
        stopReason: AgentStopReason = .endTurn)
    {
        let continuation = completions[runIndex]
        completions[runIndex] = nil
        if activeRunIndex == runIndex {
            activeRunIndex = nil
        }
        continuation?.resume(returning: AgentRunResult(stopReason: stopReason))
    }

    func fail(runIndex: Int, error: any Error) {
        let continuation = completions[runIndex]
        completions[runIndex] = nil
        if activeRunIndex == runIndex {
            activeRunIndex = nil
        }
        continuation?.resume(throwing: error)
    }
}

enum ControlledAgentRunnerError: Error, LocalizedError {
    case turnAlreadyActive
    case runFailed

    var errorDescription: String? {
        switch self {
        case .turnAlreadyActive:
            "Another fake agent turn is already active."
        case .runFailed:
            "The fake agent run failed."
        }
    }
}

func makeAgentConfiguration(
    displayName: String = "Codex",
    workingDirectory: String = "/tmp") throws -> AgentHarnessConfiguration
{
    try AgentHarnessConfiguration(
        preset: .codex,
        displayName: displayName,
        executablePath: "/usr/bin/env",
        arguments: ["agent"],
        workingDirectory: workingDirectory,
        permissionPolicy: .ask)
}

func makeAgentProfile(
    id: UUID = UUID(),
    wakePhrase: String = "agent",
    displayName: String = "Codex",
    accent: WakeProfileAccent = .purple) throws -> WakeProfile
{
    try WakeProfile(
        id: id,
        wakePhrase: wakePhrase,
        action: .agent(try makeAgentConfiguration(displayName: displayName)),
        accent: accent)
}

@Suite(.serialized)
struct VoiceActivationCoordinatorTests {
}

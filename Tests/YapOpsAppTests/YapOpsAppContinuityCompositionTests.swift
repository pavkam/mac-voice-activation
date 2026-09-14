// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import YapOpsApp
@testable import YapOpsCore

extension AppModelTests {
    @MainActor @Test
    func compositionPrompt_RealRunnerConsumesOnlyAfterFrameAndDurableAcknowledgement()
        async throws
    {
        let profile = try makeAgentProfile(pushToTalkHotKey: .defaultValue)
        let marker = compositionInterruptedMarker(profileID: profile.id)
        let order = CompositionContinuityOrder()
        let store = CompositionContinuityStore(
            markers: [marker],
            order: order)
        let transport = ScriptedCompositionACPTransport(order: order)
        var runnerStoreWasShared = false
        var modelStoreWasShared = false
        var composedRunner: ACPAgentRunner?
        let speech = AppModelSpeechSessionSpy()
        let panel = AppModelAgentPanelSpy()
        let composition = try continuityComposition(
            profile: profile,
            store: store,
            transport: transport,
            speech: speech,
            panel: panel,
            runnerStoreWasShared: { runnerStoreWasShared = $0 },
            modelStoreWasShared: { modelStoreWasShared = $0 },
            runnerCreated: { composedRunner = $0 })

        #expect(runnerStoreWasShared)
        #expect(modelStoreWasShared)
        guard runnerStoreWasShared, modelStoreWasShared else { return }
        #expect(await composition.startup.run())
        composition.model.coordinator.pushToTalkPressed(profileID: profile.id)
        speech.emit("continue")
        composition.model.coordinator.pushToTalkReleased()
        await store.waitUntilAcknowledgementEntered()

        #expect(await order.snapshot() == [.markerWritten, .promptFrame, .acknowledgementEntered])
        #expect(composition.model.interruptedAgentWork == [marker])
        #expect((await store.snapshot()).interruptedWork.contains(marker))
        await store.finishAcknowledgement()
        await panel.waitUntilPhase(.listening)

        #expect(await order.snapshot() == [
            .markerWritten,
            .promptFrame,
            .acknowledgementEntered,
            .durableAcknowledgement,
        ])
        #expect(composition.model.interruptedAgentWork.isEmpty)
        #expect(!(await store.snapshot()).interruptedWork.contains(marker))
        await composedRunner?.shutdown()
    }

    @MainActor @Test(arguments: [CompositionContinuityFailure.frame, .acknowledgement])
    func compositionPrompt_WhenRealPublicationBoundaryFails_RetainsInterruptedMarker(
        failure: CompositionContinuityFailure
    ) async throws {
        let profile = try makeAgentProfile(pushToTalkHotKey: .defaultValue)
        let marker = compositionInterruptedMarker(profileID: profile.id)
        let order = CompositionContinuityOrder()
        let store = CompositionContinuityStore(
            markers: [marker],
            order: order,
            acknowledgementFails: failure == .acknowledgement)
        let transport = ScriptedCompositionACPTransport(
            order: order,
            frameFails: failure == .frame)
        let speech = AppModelSpeechSessionSpy()
        let panel = AppModelAgentPanelSpy()
        var composedRunner: ACPAgentRunner?
        let composition = try continuityComposition(
            profile: profile,
            store: store,
            transport: transport,
            speech: speech,
            panel: panel,
            runnerCreated: { composedRunner = $0 })

        #expect(await composition.startup.run())
        composition.model.coordinator.pushToTalkPressed(profileID: profile.id)
        speech.emit("continue")
        composition.model.coordinator.pushToTalkReleased()
        if failure == .frame {
            await panel.waitUntilTerminal()
        } else {
            await panel.waitUntilPhase(.listening)
        }

        #expect(composition.model.interruptedAgentWork == [marker])
        #expect((await store.snapshot()).interruptedWork.contains(marker))
        await composedRunner?.shutdown()
    }

    @MainActor
    private func continuityComposition(
        profile: WakeProfile,
        store: CompositionContinuityStore,
        transport: ScriptedCompositionACPTransport,
        speech: AppModelSpeechSessionSpy,
        panel: AppModelAgentPanelSpy,
        runnerStoreWasShared: (Bool) -> Void = { _ in },
        modelStoreWasShared: (Bool) -> Void = { _ in },
        runnerCreated: (ACPAgentRunner) -> Void = { _ in }
    ) throws -> YapOpsAppComposition {
        let suite = InMemoryDefaults.makeSuiteName("YapOpsRealContinuityCompositionTests")
        let defaults = try #require(InMemoryDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        preferences.wakeProfiles = [profile]
        preferences.passiveEnabled = false
        return YapOpsAppComposition.make(
            continuityStore: store,
            activationMonitor: ApplicationActivationMonitor(
                notificationCenter: NotificationCenter()),
            makeAgentRunner: { sharedStore in
                runnerStoreWasShared((sharedStore as? CompositionContinuityStore) === store)
                let runner = ACPAgentRunner(
                    transportFactory: CompositionACPTransportFactory(transport: transport),
                    continuityStore: sharedStore,
                    settleClock: CompositionImmediateRunnerClock())
                runnerCreated(runner)
                return runner
            },
            makeModel: { runner, sharedStore in
                modelStoreWasShared((sharedStore as? CompositionContinuityStore) === store)
                return AppModel(
                    preferences: preferences,
                    recordingOverlay: AppModelOverlayStub(),
                    agentRunPanel: panel,
                    shortcut: ShortcutSpy(),
                    speechSession: speech,
                    agentRunner: runner,
                    continuityStore: sharedStore,
                    permissionRequest: { true },
                    soundPlayer: SilentCaptureSoundPlayer(),
                    agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
                    agentSpeechCredentialStore: AgentSpeechCredentialStoreSpy(),
                    elevenLabsVoiceCatalog: AppModelElevenLabsVoiceCatalogSpy(voices: []),
                    textToSpeechVoicePreview: AppModelTextToSpeechVoicePreviewSpy(),
                    macContextAccess: MacContextAccessSpy(),
                    macContextCapturer: MacContextCapturerSpy(),
                    isExecutableFile: { _ in true },
                    isDirectory: { _ in true },
                    startsAutomatically: false)
            })
    }

    private func compositionInterruptedMarker(profileID: UUID) -> AgentInterruptedWorkMarker {
        AgentInterruptedWorkMarker(
            key: AgentInterruptedWorkKey(
                profileID: profileID,
                sessionID: "saved-session",
                occurrenceID: UUID()),
            state: .interruptedByProcessExit)
    }
}

enum CompositionContinuityFailure: Sendable {
    case frame
    case acknowledgement
}

private actor CompositionContinuityOrder {
    enum Event: Equatable {
        case markerWritten
        case promptFrame
        case acknowledgementEntered
        case durableAcknowledgement
    }

    private var events: [Event] = []
    func append(_ event: Event) { events.append(event) }
    func snapshot() -> [Event] { events }
}

private actor CompositionContinuityStore: AgentContinuityStoring {
    private var envelope: AgentContinuityEnvelope
    private let order: CompositionContinuityOrder
    private let acknowledgementFails: Bool
    private var acknowledgementContinuation: CheckedContinuation<Void, Never>?
    private var acknowledgementWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        markers: [AgentInterruptedWorkMarker],
        order: CompositionContinuityOrder,
        acknowledgementFails: Bool = false
    ) {
        envelope = AgentContinuityEnvelope(
            schemaVersion: AgentContinuityStorePolicy.schemaVersion,
            bookmarks: [],
            interruptedWork: markers)
        self.order = order
        self.acknowledgementFails = acknowledgementFails
    }

    func bookmark(for profileID: UUID) async throws -> AgentSessionBookmark? {
        try AgentContinuityStorePolicy.bookmark(for: profileID, in: &envelope)
    }

    func save(bookmark: AgentSessionBookmark) async throws {
        try AgentContinuityStorePolicy.save(bookmark, in: &envelope)
    }

    func remove(profileIDs: Set<UUID>) async throws {
        try AgentContinuityStorePolicy.remove(profileIDs: profileIDs, in: &envelope)
    }

    func markWorkActive(_ marker: AgentInterruptedWorkMarker) async throws {
        try AgentContinuityStorePolicy.markWorkActive(marker, in: &envelope)
        await order.append(.markerWritten)
    }

    func clearWork(_ key: AgentInterruptedWorkKey) async throws {
        try AgentContinuityStorePolicy.clearWork(key, in: &envelope)
    }

    func reconcileInterruptedWork() async throws -> [AgentInterruptedWorkMarker] {
        try AgentContinuityStorePolicy.reconcileInterruptedWork(in: &envelope)
    }

    func acknowledgeInterruptedWork(_ keys: Set<AgentInterruptedWorkKey>) async throws {
        await order.append(.acknowledgementEntered)
        if acknowledgementFails { throw CompositionContinuityStoreError.acknowledgement }
        let waiters = acknowledgementWaiters
        acknowledgementWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { acknowledgementContinuation = $0 }
        try AgentContinuityStorePolicy.acknowledgeInterruptedWork(keys, in: &envelope)
        await order.append(.durableAcknowledgement)
    }

    func waitUntilAcknowledgementEntered() async {
        guard acknowledgementContinuation == nil else { return }
        await withCheckedContinuation { acknowledgementWaiters.append($0) }
    }

    func finishAcknowledgement() {
        acknowledgementContinuation?.resume()
        acknowledgementContinuation = nil
    }

    func snapshot() -> AgentContinuityEnvelope { envelope }
}

private enum CompositionContinuityStoreError: Error {
    case acknowledgement
}

private enum ScriptedCompositionACPTransportError: Error {
    case invalidFrame
    case frameFailed
}

private actor ScriptedCompositionACPTransport: ACPTransport {
    private let order: CompositionContinuityOrder
    private let frameFails: Bool
    private let outputStream: AsyncThrowingStream<Data, any Error>
    private let outputContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let diagnosticStream: AsyncStream<Data>
    private let diagnosticContinuation: AsyncStream<Data>.Continuation
    private var exitContinuation: CheckedContinuation<Int32, Never>?
    private var exitStatus: Int32?

    init(order: CompositionContinuityOrder, frameFails: Bool = false) {
        self.order = order
        self.frameFails = frameFails
        let output = AsyncThrowingStream<Data, any Error>.makeStream()
        outputStream = output.stream
        outputContinuation = output.continuation
        let diagnostics = AsyncStream<Data>.makeStream()
        diagnosticStream = diagnostics.stream
        diagnosticContinuation = diagnostics.continuation
    }

    func output() async -> AsyncThrowingStream<Data, any Error> { outputStream }
    func diagnostics() async -> AsyncStream<Data> { diagnosticStream }

    func send(_ data: Data) async throws {
        guard data.last == 0x0A,
            let message = try? JSONDecoder().decode(ACPMessage.self, from: data.dropLast()),
            case .request(let id, let method, _) = message
        else { throw ScriptedCompositionACPTransportError.invalidFrame }
        switch method {
        case "initialize":
            feed(.response(
                id: id,
                result: .object([
                    "protocolVersion": .integer(1),
                    "agentCapabilities": .object([:]),
                    "agentInfo": .object([
                        "name": .string("test-agent"),
                        "version": .string("1.0.0"),
                    ]),
                    "authMethods": .array([]),
                ])))
        case "session/new":
            feed(.response(
                id: id,
                result: .object(["sessionId": .string("saved-session")])))
        case "session/prompt":
            if frameFails { throw ScriptedCompositionACPTransportError.frameFailed }
            await order.append(.promptFrame)
            feed(.response(id: id, result: .object(["stopReason": .string("end_turn")])))
        default:
            break
        }
    }

    func waitForExit() async -> Int32 {
        if let exitStatus { return exitStatus }
        return await withCheckedContinuation { exitContinuation = $0 }
    }

    func waitForDrain() async {}
    func closeReadStreams() async { finish(status: -15) }
    func terminate() async { finish(status: -15) }

    private func feed(_ message: ACPMessage) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        outputContinuation.yield(data)
    }

    private func finish(status: Int32) {
        guard exitStatus == nil else { return }
        exitStatus = status
        outputContinuation.finish()
        diagnosticContinuation.finish()
        exitContinuation?.resume(returning: status)
        exitContinuation = nil
    }
}

private actor CompositionACPTransportFactory: ACPTransportCreating {
    let transport: ScriptedCompositionACPTransport

    init(transport: ScriptedCompositionACPTransport) {
        self.transport = transport
    }

    func makeTransport(configuration: AgentHarnessConfiguration) async throws -> any ACPTransport {
        transport
    }
}

private struct CompositionImmediateRunnerClock: ACPAgentRunnerClock {
    func sleep(for duration: Duration) async {}
}

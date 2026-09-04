// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore

private actor DeliveryEventRecorder {
    private var events: [AgentRunEvent] = []

    func record(_ event: AgentRunEvent) {
        events.append(event)
    }

    func recordedEvents() -> [AgentRunEvent] {
        events
    }
}

private actor DeliveryHandlerGate {
    private var didEnter = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        didEnter = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else {
            return
        }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor DeliveryCompletionProbe {
    private var didComplete = false

    func complete() {
        didComplete = true
    }

    func completed() -> Bool {
        didComplete
    }
}

@Suite(.serialized)
struct AgentRunEventDeliveryTests {
    @Test func send_WhenHandlerIsStalled_KeepsTenThousandDeltasWithinEveryBound() async {
        let gate = DeliveryHandlerGate()
        let delivery = AgentRunEventDelivery { _ in await gate.wait() }

        #expect(delivery.send(.connected(agentName: "Agent", sessionID: "session")) == .accepted)
        await gate.waitUntilEntered()
        for _ in 0..<10_000 {
            #expect(delivery.send(.agentMessageDelta(messageID: "message", text: "x")) == .accepted)
            #expect(delivery.send(.agentMessageDelta(messageID: "message", text: "")) == .ignored)
        }

        let snapshot = delivery.snapshotForTesting
        #expect(snapshot.pendingOutputBytes == 10_000)
        #expect(snapshot.pendingDiagnosticBytes == 0)
        #expect(snapshot.pendingControlBytes == "message".utf8.count)
        #expect(snapshot.pendingEntryCount == 1)
        #expect(snapshot.pendingOutputBytes <= AgentRunEventDelivery.maximumPendingOutputBytes)
        #expect(snapshot.pendingDiagnosticBytes <= AgentRunEventDelivery.maximumPendingDiagnosticBytes)
        #expect(snapshot.pendingControlBytes <= AgentRunEventDelivery.maximumPendingControlBytes)
        #expect(snapshot.pendingEntryCount <= AgentRunEventDelivery.maximumPendingEntries)

        await delivery.finish(.discard)
        #expect(delivery.snapshotForTesting.pendingEntryCount == 0)
        await gate.open()
    }

    @Test func send_WhenOneMultibyteDeltaExceedsTheBound_RetainsValidSuffixAfterOneTypedNotice()
        async
    {
        let recorder = DeliveryEventRecorder()
        let delivery = AgentRunEventDelivery { event in await recorder.record(event) }
        let retainedScalarCount = AgentRunEventDelivery.maximumPendingOutputBytes / 4
        let oversized = "prefix" + String(repeating: "🧪", count: retainedScalarCount + 1)

        #expect(delivery.send(.agentMessageDelta(messageID: "message", text: oversized)) == .accepted)
        await delivery.finish(.drain)

        let events = await recorder.recordedEvents()
        #expect(events == [
            .deliveryNotice(AgentRunEventDeliveryNotice(
                kind: .outputTruncated,
                discardedBytes: 10,
                discardedEntries: 0)),
            .agentMessageDelta(
                messageID: "message",
                text: String(repeating: "🧪", count: retainedScalarCount)),
        ])
        guard case let .agentMessageDelta(_, text) = events.last else {
            Issue.record("Expected retained output")
            return
        }
        #expect(String(data: Data(text.utf8), encoding: .utf8) == text)
        #expect(text.utf8.count == AgentRunEventDelivery.maximumPendingOutputBytes)
    }

    @Test func send_WhenDeltaIsExactlyAtTheBound_PreservesItWithoutNotice() async {
        let recorder = DeliveryEventRecorder()
        let delivery = AgentRunEventDelivery { event in await recorder.record(event) }
        let exact = String(
            repeating: "x",
            count: AgentRunEventDelivery.maximumPendingOutputBytes)

        #expect(delivery.send(.thoughtDelta(messageID: nil, text: exact)) == .accepted)
        await delivery.finish(.drain)

        #expect(await recorder.recordedEvents() == [
            .thoughtDelta(messageID: nil, text: exact),
        ])
    }

    @Test func send_WhenCasesAndMessageIdentifiersAlternate_CannotEvadeTheEntryCap() async {
        let gate = DeliveryHandlerGate()
        let delivery = AgentRunEventDelivery { _ in await gate.wait() }
        #expect(delivery.send(.connected(agentName: "Agent", sessionID: "session")) == .accepted)
        await gate.waitUntilEntered()

        for index in 0..<10_000 {
            let event: AgentRunEvent = if index.isMultiple(of: 2) {
                .agentMessageDelta(messageID: "message-\(index)", text: "m")
            } else {
                .thoughtDelta(messageID: "thought-\(index)", text: "t")
            }
            #expect(delivery.send(event) == .accepted)
        }

        let snapshot = delivery.snapshotForTesting
        #expect(snapshot.pendingEntryCount <= AgentRunEventDelivery.maximumPendingEntries)
        #expect(snapshot.pendingOutputBytes <= AgentRunEventDelivery.maximumPendingOutputBytes)
        #expect(snapshot.discardedOutputEntries > 0)
        await delivery.finish(.discard)
        await gate.open()
    }

    @Test func send_WhenControlEventsSeparateMessages_DrainsInExactBarrierOrder() async {
        let recorder = DeliveryEventRecorder()
        let gate = DeliveryHandlerGate()
        let delivery = AgentRunEventDelivery { event in
            await gate.wait()
            await recorder.record(event)
        }
        let turnToken = AgentTurnToken()
        let permission = AgentPermissionRequest(
            turnToken: turnToken,
            requestID: .string("permission"),
            toolCall: AgentToolCallUpdate(id: "tool", title: "Edit"),
            options: [
                AgentPermissionOption(id: "once", label: "Allow once", kind: .allowOnce),
            ])
        let expected: [AgentRunEvent] = [
            .connected(agentName: "Agent", sessionID: "session"),
            .agentMessageDelta(messageID: "first", text: "Hello world"),
            .toolCall(AgentToolCall(id: "tool", title: "Edit")),
            .plan([AgentPlanEntry(content: "Verify", priority: .high, status: .pending)]),
            .permissionRequested(permission),
            .agentMessageDelta(messageID: "second", text: "Done"),
        ]

        #expect(delivery.send(expected[0]) == .accepted)
        await gate.waitUntilEntered()
        #expect(delivery.send(.agentMessageDelta(messageID: "first", text: "Hello")) == .accepted)
        #expect(delivery.send(.agentMessageDelta(messageID: "first", text: " world")) == .accepted)
        for event in expected.dropFirst(2) {
            #expect(delivery.send(event) == .accepted)
        }
        await gate.open()
        await delivery.finish(.drain)

        #expect(await recorder.recordedEvents() == expected)
    }

    @Test func send_WhenControlOnlyReserveFills_FailsExplicitlyAfterAdmittedPrefix() async {
        let recorder = DeliveryEventRecorder()
        let gate = DeliveryHandlerGate()
        let delivery = AgentRunEventDelivery { event in
            await gate.wait()
            await recorder.record(event)
        }
        let first = AgentRunEvent.connected(agentName: "Agent", sessionID: "session")
        #expect(delivery.send(first) == .accepted)
        await gate.waitUntilEntered()

        var admitted: [AgentRunEvent] = [first]
        for index in 0..<AgentRunEventDelivery.maximumPendingEntries {
            let event = AgentRunEvent.metadata(kind: "control", summary: "event-\(index)")
            #expect(delivery.send(event) == .accepted)
            admitted.append(event)
        }
        #expect(delivery.send(.metadata(kind: "control", summary: "overflow")) == .capacityExceeded)
        #expect(delivery.send(.metadata(kind: "control", summary: "after")) == .stopped)

        let draining = Task { await delivery.finish(.drain) }
        await gate.open()
        await draining.value
        #expect(await recorder.recordedEvents() == admitted)
    }

    @Test func finish_WhenDraining_WaitsForTheInFlightHandler() async {
        let gate = DeliveryHandlerGate()
        let completion = DeliveryCompletionProbe()
        let delivery = AgentRunEventDelivery { _ in await gate.wait() }
        #expect(delivery.send(.diagnostic("wait")) == .accepted)
        await gate.waitUntilEntered()

        let finishing = Task {
            await delivery.finish(.drain)
            await completion.complete()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(await completion.completed() == false)

        await gate.open()
        await finishing.value
        #expect(await completion.completed())
    }

    @Test func finish_WhenDiscarding_ClearsPendingAndReturnsWithoutWaitingForHandler() async {
        let gate = DeliveryHandlerGate()
        let completion = DeliveryCompletionProbe()
        let delivery = AgentRunEventDelivery { _ in await gate.wait() }
        #expect(delivery.send(.diagnostic("in flight")) == .accepted)
        await gate.waitUntilEntered()
        #expect(delivery.send(.diagnostic("pending")) == .accepted)

        await delivery.finish(.discard)
        await completion.complete()

        #expect(await completion.completed())
        #expect(delivery.snapshotForTesting.pendingEntryCount == 0)
        #expect(delivery.snapshotForTesting.state == .discarded)
        await gate.open()
    }

    @Test func finish_WhenNextIsSuspended_ResumesTheConsumer() async {
        let delivery = AgentRunEventDelivery { _ in }
        for _ in 0..<20 {
            await Task.yield()
        }

        await delivery.finish(.discard)
        await delivery.waitForConsumerTerminationForTesting()

        #expect(delivery.snapshotForTesting.state == .discarded)
    }
}

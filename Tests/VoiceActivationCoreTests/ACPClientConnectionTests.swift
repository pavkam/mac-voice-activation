// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore

actor AgentEventRecorder {
    private var events: [AgentRunEvent] = []
    private var waiters: [CheckedContinuation<AgentRunEvent, Never>] = []

    func record(_ event: AgentRunEvent) {
        if waiters.isEmpty {
            events.append(event)
        } else {
            waiters.removeFirst().resume(returning: event)
        }
    }

    func nextEvent() async -> AgentRunEvent {
        if !events.isEmpty {
            return events.removeFirst()
        }

        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func recordedEvents() -> [AgentRunEvent] {
        events
    }
}

actor AgentEventGate {
    private var entered = false
    private var isOpen = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
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
        guard !entered else {
            return
        }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
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

actor AgentEventSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isSignalled else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func observedSignal() -> Bool {
        isSignalled
    }
}

@Suite(.serialized)
struct ACPClientConnectionTests {
}

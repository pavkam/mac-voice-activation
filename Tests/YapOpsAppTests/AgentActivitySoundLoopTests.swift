// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Testing

@testable import YapOpsApp
@testable import YapOpsCore

private actor ManualActivitySleeper {
    private struct Waiter {
        let id: UUID
        let delay: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [Waiter] = []

    var delays: [Duration] {
        waiters.map(\.delay)
    }

    func sleep(for delay: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(
                        Waiter(
                            id: id,
                            delay: delay,
                            continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func advance() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

@MainActor
private final class ActivitySoundPlayerRecorder: AgentActivitySoundPlaying {
    private(set) var sounds: [AgentActivitySound] = []
    private(set) var stopCount = 0
    private(set) var lastRunLoopMode: RunLoop.Mode?

    func play(_ sound: AgentActivitySound) {
        sounds.append(sound)
        lastRunLoopMode = RunLoop.current.currentMode
    }

    func stop() {
        stopCount += 1
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AgentActivitySoundLoopTests {
    private static let trackingChildKey = "YAPOPS_ACTIVITY_TRACKING_TEST_CHILD"
    private static let trackingTestFilter =
        "pulse_WhenAppKitTracksEvents_PlaysWithoutWaitingForDefaultMode"

    @MainActor @Test
    func pulse_WhenAppKitTracksEvents_PlaysWithoutWaitingForDefaultMode() async throws {
        guard ProcessInfo.processInfo.environment[Self.trackingChildKey] == "1" else {
            try await IsolatedAppKitTestProcess.run(
                environmentKey: Self.trackingChildKey, testFilter: Self.trackingTestFilter)
            return
        }

        let sleeper = ManualActivitySleeper()
        let player = ActivitySoundPlayerRecorder()
        let loop = AgentActivitySoundLoop(
            player: player,
            interval: .seconds(5),
            sleep: { try await sleeper.sleep(for: $0) })
        defer { loop.stop() }
        loop.setWorking(true)
        try await waitUntil { await sleeper.delays == [.seconds(5)] }
        RunLoop.main.perform(inModes: [.eventTracking]) {
            Task.detached { await sleeper.advance() }
        }

        runActivityEventTrackingLoop {
            player.sounds.count == 1
        }
        let sounds = player.sounds

        #expect(sounds == [.thinking, .thinking])
        #expect(player.lastRunLoopMode == .eventTracking)
    }

    @MainActor @Test func setWorking_WhenEnabled_RecordsImmediateAndScheduledSoundState()
        async throws
    {
        let diagnostics = AppDiagnosticRecorderSpy()
        let sleeper = ManualActivitySleeper()
        let loop = AgentActivitySoundLoop(
            player: ActivitySoundPlayerRecorder(),
            initialDelay: .seconds(2),
            interval: .seconds(5),
            sleep: { try await sleeper.sleep(for: $0) },
            diagnostics: diagnostics)

        defer { loop.stop() }
        loop.setWorking(true)
        try await waitUntil { await sleeper.delays == [.seconds(5)] }

        let events = diagnostics.snapshot().map(\.event)
        #expect(events.contains("activity.working_changed"))
        #expect(events.contains("activity.sound_requested"))
        #expect(events.contains("activity.pulse_scheduled"))
    }

    @MainActor @Test func setWorking_WhenEnabled_PlaysImmediatelyThenRepeatsOnClock()
        async throws
    {
        let sleeper = ManualActivitySleeper()
        let player = ActivitySoundPlayerRecorder()
        let loop = AgentActivitySoundLoop(
            player: player,
            initialDelay: .seconds(2),
            interval: .seconds(5),
            sleep: { try await sleeper.sleep(for: $0) })

        defer { loop.stop() }
        loop.setWorking(true)
        try await waitUntil { await sleeper.delays == [.seconds(5)] }
        #expect(player.sounds == [.thinking])

        await sleeper.advance()
        try await waitUntil {
            guard player.sounds == [.thinking, .thinking] else { return false }
            return await sleeper.delays == [.seconds(5)]
        }
        #expect(player.sounds == [.thinking, .thinking])
        #expect(await sleeper.delays == [.seconds(5)])
    }

    @MainActor @Test
    func setSpeechSuppressed_WhenPlaybackEnds_ResumesAfterInitialDelay() async throws {
        let sleeper = ManualActivitySleeper()
        let player = ActivitySoundPlayerRecorder()
        let loop = AgentActivitySoundLoop(
            player: player,
            initialDelay: .seconds(2),
            interval: .seconds(5),
            sleep: { try await sleeper.sleep(for: $0) })
        defer { loop.stop() }
        loop.setWorking(true)
        try await waitUntil { await sleeper.delays == [.seconds(5)] }

        loop.setSpeechSuppressed(true)
        try await waitUntil { await sleeper.delays.isEmpty }
        loop.setSpeechSuppressed(false)
        try await waitUntil { await sleeper.delays == [.seconds(2)] }
        #expect(player.sounds == [.thinking])

        await sleeper.advance()
        try await waitUntil {
            guard player.sounds == [.thinking, .thinking] else { return false }
            return await sleeper.delays == [.seconds(5)]
        }
        #expect(player.sounds == [.thinking, .thinking])
        #expect(await sleeper.delays == [.seconds(5)])
    }

    @MainActor @Test func play_WhenToolCueArrives_RestartsPulseFromInitialDelay()
        async throws
    {
        let sleeper = ManualActivitySleeper()
        let player = ActivitySoundPlayerRecorder()
        let loop = AgentActivitySoundLoop(
            player: player,
            initialDelay: .seconds(2),
            interval: .seconds(5),
            sleep: { try await sleeper.sleep(for: $0) })
        defer { loop.stop() }
        loop.setWorking(true)
        try await waitUntil { await sleeper.delays == [.seconds(5)] }

        loop.play(.toolStarted)
        try await waitUntil { await sleeper.delays == [.seconds(2)] }

        #expect(player.sounds == [.thinking, .toolStarted])
    }

    /// Waits for a condition that must cover every observable the test then
    /// asserts. A pulse plays its sound before the next sleeper waiter is
    /// registered, so waiting only for `player.sounds` and inferring the
    /// waiter races the detached task that registers it.
    @MainActor
    private func waitUntil(
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        while true {
            try Task.checkCancellation()
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private func runActivityEventTrackingLoop(while condition: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 2)
    while condition(), Date() < deadline {
        _ = RunLoop.main.run(
            mode: .eventTracking,
            before: min(deadline, Date(timeIntervalSinceNow: 0.01)))
    }
}

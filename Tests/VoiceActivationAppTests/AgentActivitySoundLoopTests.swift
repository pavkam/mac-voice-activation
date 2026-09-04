// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import VoiceActivationApp
@testable import VoiceActivationCore

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

    func play(_ sound: AgentActivitySound) {
        sounds.append(sound)
    }

    func stop() {
        stopCount += 1
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AgentActivitySoundLoopTests {
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

        loop.setWorking(true)
        try await waitUntil { await sleeper.delays == [.seconds(5)] }

        let events = diagnostics.snapshot().map(\.event)
        #expect(events.contains("activity.working_changed"))
        #expect(events.contains("activity.sound_requested"))
        #expect(events.contains("activity.pulse_scheduled"))
        loop.stop()
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

        loop.setWorking(true)
        try await waitUntil { await sleeper.delays == [.seconds(5)] }
        #expect(player.sounds == [.thinking])

        await sleeper.advance()
        try await waitUntil { player.sounds == [.thinking, .thinking] }
        #expect(await sleeper.delays == [.seconds(5)])
        loop.stop()
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
        loop.setWorking(true)
        try await waitUntil { await sleeper.delays == [.seconds(5)] }

        loop.setSpeechSuppressed(true)
        try await waitUntil { await sleeper.delays.isEmpty }
        loop.setSpeechSuppressed(false)
        try await waitUntil { await sleeper.delays == [.seconds(2)] }
        #expect(player.sounds == [.thinking])

        await sleeper.advance()
        try await waitUntil { player.sounds == [.thinking, .thinking] }
        loop.stop()
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
        loop.setWorking(true)
        try await waitUntil { await sleeper.delays == [.seconds(5)] }

        loop.play(.toolStarted)
        try await waitUntil { await sleeper.delays == [.seconds(2)] }

        #expect(player.sounds == [.thinking, .toolStarted])
        loop.stop()
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TimeoutError()
    }

    private struct TimeoutError: Error {}
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import YapOpsCore


extension YapOpsCoordinatorTests {
    @MainActor
    struct Fixture {
        let speech = FakeSpeechSession()
        let runner = RecordingCommandRunner()
        let agentRunner: ControlledAgentRunner
        let systemActions: RecordingSystemActionPerformer
        let coordinator: YapOpsCoordinator

        init(
            timing: ActivationTiming = .standard,
            profiles: [WakeProfile]? = nil,
            agentRunner: ControlledAgentRunner = ControlledAgentRunner(),
            systemActions: RecordingSystemActionPerformer = RecordingSystemActionPerformer(),
            contextCapturer: any MacContextCapturing = EmptyMacContextCapturer(),
            terminalPhrases: @escaping () -> [String] = { AppPreferences.defaultTerminalPhrases },
            diagnostics: any YapOpsDiagnosticRecording = YapOpsDiagnostics.shared
        ) throws
        {
            self.agentRunner = agentRunner
            self.systemActions = systemActions
            let template = try CommandTemplate(
                executablePath: "/usr/bin/printf",
                argumentTemplates: ["{text}"])
            coordinator = YapOpsCoordinator(
                speechSession: speech,
                commandRunner: runner,
                agentRunner: agentRunner,
                systemActionPerformer: systemActions,
                contextCapturer: contextCapturer,
                configuration: {
                    if let profiles {
                        return ActivationConfiguration(profiles: profiles, localeID: "en-US")
                    }
                    return ActivationConfiguration(
                        wakePhrase: "computer",
                        localeID: "en-US",
                        commandTemplate: template)
                },
                terminalPhrases: terminalPhrases,
                timing: timing,
                diagnostics: diagnostics)
        }
    }

    /// Polls until `condition` holds, failing if it does not inside `timeout`.
    ///
    /// Some callers pass a deliberately tight budget, so the timeout has to
    /// keep meaning what it says. What it must not measure is this loop's own
    /// starvation. The suite runs in parallel, and under a sanitizer a 10ms
    /// poll sleep routinely overshoots by an order of magnitude, which leaves
    /// a tight budget only a couple of samples and lets the condition come
    /// true unobserved.
    ///
    /// Prefer a handshake — see `RecordingSystemActionPerformer.waitForActions`
    /// — when the component can signal directly; polling is the fallback for
    /// state that publishes no such edge.
    ///
    /// So time spent descheduled is given back to the deadline: it is time
    /// the test runner took, not time the system under test took. A system
    /// that is genuinely slow while polling is healthy still fails, and the
    /// credit is capped so a permanently false condition cannot stall the
    /// suite. The condition is always evaluated once more before recording a
    /// failure, so a timeout is never reported without having looked.
    @MainActor func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () async -> Bool) async
    {
        let clock = ContinuousClock()
        let pollInterval = Duration.milliseconds(10)
        let start = clock.now
        let ceiling = start.advanced(by: max(timeout * 10, .seconds(5)))
        var deadline = start.advanced(by: timeout)

        var iterationStart = start
        while true {
            if await condition() { return }
            let polledAt = clock.now
            guard polledAt < deadline, polledAt < ceiling else { break }

            await Task.yield()
            try? await Task.sleep(for: pollInterval)

            // Everything this iteration spent beyond the poll interval is the
            // loop's own cost — the sleep overshooting and the actor hop into
            // `condition` — not the system under test being slow.
            let overshoot = (clock.now - iterationStart) - pollInterval
            if overshoot > .zero {
                deadline = deadline.advanced(by: overshoot)
            }
            iterationStart = clock.now
        }
        Issue.record("Condition was not satisfied before timeout")
    }
}

extension ActivationTiming {
    static let fast = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(200),
        captureInactivity: .milliseconds(20),
        captureMaximum: .milliseconds(40),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let startFailure = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(20),
        captureInactivity: .milliseconds(20),
        captureMaximum: .milliseconds(200),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let initialSilence = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(20),
        captureInactivity: .milliseconds(200),
        captureMaximum: .milliseconds(200),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let initialSilenceCancellation = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(50),
        captureInactivity: .seconds(5),
        captureMaximum: .seconds(10),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let repeatingEmptyFinals = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(500),
        captureInactivity: .milliseconds(500),
        captureMaximum: .milliseconds(200),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let wakeHandoff = ActivationTiming(
        wakeHandoffDelay: .milliseconds(20),
        captureInitialSilence: .milliseconds(200),
        captureInactivity: .milliseconds(20),
        captureMaximum: .milliseconds(500),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    /// Capture windows no test can wait out.
    ///
    /// Only an early dispatch can reach execution under this timing, so a
    /// system action that runs proves it settled before the utterance ended,
    /// and one that does not run cannot be rescued later by a timer.
    static let unreachableCapture = ActivationTiming(
        wakeHandoffDelay: .seconds(3_600),
        captureInitialSilence: .seconds(3_600),
        captureInactivity: .seconds(3_600),
        captureMaximum: .seconds(3_600),
        passiveRestart: .seconds(3_600),
        executionCooldown: .milliseconds(10))

    static let pendingPassiveRestart = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(200),
        captureInactivity: .milliseconds(20),
        captureMaximum: .milliseconds(500),
        passiveRestart: .milliseconds(20),
        executionCooldown: .milliseconds(10))
}


/// Records performed actions and can be told to fail the next one.
///
/// `waitForActions(count:)` is a handshake, not a deadline: it resumes the
/// moment the performer has recorded enough actions, so a test never has to
/// guess how long a loaded machine needs. Pair it with `.timeLimit` so a
/// genuinely stuck run still fails instead of hanging.
actor RecordingSystemActionPerformer: SystemActionPerforming {
    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var performed: [SystemAction] = []
    private var failure: (any Error)?
    private var waiters: [UUID: Waiter] = [:]

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    func perform(_ action: SystemAction) async throws {
        if let failure {
            throw failure
        }
        performed.append(action)
        for (id, waiter) in waiters where performed.count >= waiter.count {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    func recordedActions() -> [SystemAction] {
        performed
    }

    /// Suspends until at least `count` actions have been performed.
    ///
    /// Cancellation resumes the waiter instead of stranding it, so an expiring
    /// `.timeLimit` reports the test as failed rather than hanging the run.
    func waitForActions(count: Int = 1) async {
        guard performed.count < count else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard performed.count < count, !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                waiters[id] = Waiter(count: count, continuation: continuation)
            }
        } onCancel: {
            Task { await self.releaseWaiter(id) }
        }
    }

    private func releaseWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import CoreFoundation
import Foundation

/// Delivers latency-sensitive main-actor work through every AppKit run-loop mode.
///
/// AppKit enters nested modal and event-tracking loops while menus, panels, drags,
/// and controls are active. Ordinary main-actor task continuations can remain
/// queued until those loops return. This scheduler keeps UI, speech, and agent
/// streaming callbacks live by explicitly registering their drain in each mode.
package final class MainRunLoopScheduler: @unchecked Sendable {
    /// A synchronous unit of work that owns or updates main-actor state.
    package typealias Operation = @MainActor @Sendable () -> Void

    /// The process-wide ordered scheduler used by production callback bridges.
    package static let shared = MainRunLoopScheduler()

    private static let supportedModes: [RunLoop.Mode] = [
        .default,
        .common,
        RunLoop.Mode("NSModalPanelRunLoopMode"),
        RunLoop.Mode("NSEventTrackingRunLoopMode"),
    ]

    private let lock = NSLock()
    private var pendingOperations: [Operation] = []
    private var isDrainScheduled = false

    /// Creates an independent ordered scheduler, primarily for deterministic tests.
    package init() {}

    /// Enqueues work for the main actor without depending on the default run-loop mode.
    ///
    /// Calls from any thread are safe. Operations are invoked in submission order.
    ///
    /// - Parameter operation: Brief UI-affine work to perform on the main actor.
    package func schedule(_ operation: @escaping Operation) {
        let shouldScheduleDrain = lock.withLock {
            pendingOperations.append(operation)
            guard !isDrainScheduled else { return false }
            isDrainScheduled = true
            return true
        }
        guard shouldScheduleDrain else { return }

        RunLoop.main.perform(inModes: Self.supportedModes) { [weak self] in
            MainActor.assumeIsolated {
                self?.drain()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Suspends a producer until its main-actor operation has been delivered.
    ///
    /// This form preserves upstream backpressure for bounded streaming queues while
    /// still remaining live in nested AppKit run-loop modes.
    ///
    /// - Parameter operation: Brief UI-affine work to perform on the main actor.
    package func perform(_ operation: @escaping Operation) async {
        await withCheckedContinuation { continuation in
            schedule {
                operation()
                continuation.resume()
            }
        }
    }

    /// Sleeps off the main actor, then submits work through the mode-aware queue.
    ///
    /// Cancelling the returned task before the delay expires prevents submission.
    /// Callers whose state can be replaced should additionally validate a generation
    /// or identity inside `operation` to reject a callback already submitted.
    ///
    /// - Parameters:
    ///   - delay: The monotonic duration to wait before submission.
    ///   - priority: The task priority used only by the off-main delay.
    ///   - operation: Brief UI-affine work to perform after the delay.
    /// - Returns: A cancellable handle for the pending delay.
    package func schedule(
        after delay: Duration,
        priority: TaskPriority = .userInitiated,
        _ operation: @escaping Operation
    ) -> Task<Void, Never> {
        Task.detached(priority: priority) { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.schedule(operation)
        }
    }

    @MainActor
    private func drain() {
        let operations = lock.withLock {
            let operations = pendingOperations
            pendingOperations.removeAll(keepingCapacity: true)
            isDrainScheduled = false
            return operations
        }
        for operation in operations {
            operation()
        }
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// Retries an Accessibility status check until it reports authorized, or a
/// bounded number of attempts run out.
///
/// macOS can cache `AXIsProcessTrusted()`'s result for an already-running
/// process, particularly right after the Accessibility checkbox is toggled
/// off and back on in the same session — `AppModel`'s own
/// `.didBecomeActive`/Settings-appear refresh can arrive before that cache
/// actually clears. This converges on the true state within a few seconds
/// without the user needing to know why, and costs nothing once authorized:
/// a poll already in flight is cancelled, and a new one that finds the
/// status already authorized never starts.
@MainActor
final class MacContextAccessPoller {
    private let interval: Duration
    private let maximumAttempts: Int
    private let clock: any Clock<Duration>
    private var task: Task<Void, Never>?

    init(
        interval: Duration = .seconds(1),
        maximumAttempts: Int = 10,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.interval = interval
        self.maximumAttempts = maximumAttempts
        self.clock = clock
    }

    /// Starts polling, superseding any poll already in flight.
    ///
    /// - Parameters:
    ///   - refresh: Re-reads the current status and applies it.
    ///   - isAuthorized: Reports whether the just-applied status is
    ///     authorized, so the loop can stop as soon as it is.
    func start(refresh: @escaping () -> Void, isAuthorized: @escaping () -> Bool) {
        task?.cancel()
        guard !isAuthorized() else { return }

        task = Task { [interval, maximumAttempts, clock] in
            for _ in 0..<maximumAttempts {
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                refresh()
                if isAuthorized() { return }
            }
        }
    }

    /// Stops polling, e.g. when the owning view disappears.
    func stop() {
        task?.cancel()
        task = nil
    }

    /// Awaits the in-flight poll, for deterministic tests. Production never
    /// needs this.
    func settle() async {
        await task?.value
    }
}

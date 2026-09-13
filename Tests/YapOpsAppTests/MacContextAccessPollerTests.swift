// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import YapOpsApp

@MainActor
@Suite struct MacContextAccessPollerTests {
    /// The scenario this exists for: the status the user actually granted
    /// only becomes visible a couple of checks in, mirroring a stale
    /// AXIsProcessTrusted() cache clearing after a real delay.
    @Test func pollingConvergesOnceTheStatusBecomesAuthorized() async {
        let poller = MacContextAccessPoller(interval: .zero, clock: ManualTestClock())
        var refreshCount = 0
        var isAuthorized = false

        poller.start(
            refresh: {
                refreshCount += 1
                if refreshCount == 3 { isAuthorized = true }
            },
            isAuthorized: { isAuthorized })
        await poller.settle()

        #expect(refreshCount == 3)
        #expect(isAuthorized)
    }

    @Test func pollingStopsAfterTheAttemptLimitIfNeverAuthorized() async {
        let poller = MacContextAccessPoller(
            interval: .zero, maximumAttempts: 4, clock: ManualTestClock())
        var refreshCount = 0

        poller.start(refresh: { refreshCount += 1 }, isAuthorized: { false })
        await poller.settle()

        #expect(refreshCount == 4)
    }

    /// If the status is already authorized by the time polling would start,
    /// it must not check again — the manual "Recheck" button already covers
    /// the immediate case, and refreshing something already true is noise.
    @Test func startDoesNothingWhenAlreadyAuthorized() async {
        let poller = MacContextAccessPoller(interval: .zero, clock: ManualTestClock())
        var refreshCount = 0

        poller.start(refresh: { refreshCount += 1 }, isAuthorized: { true })
        await poller.settle()

        #expect(refreshCount == 0)
    }

    /// Stopping (the view disappearing) must cancel work in flight rather
    /// than let a stale poll keep firing into a torn-down section.
    @Test func stopCancelsAPollInFlight() async {
        let poller = MacContextAccessPoller(
            interval: .milliseconds(50), maximumAttempts: 100, clock: ManualTestClock())
        var refreshCount = 0

        poller.start(refresh: { refreshCount += 1 }, isAuthorized: { false })
        poller.stop()
        await poller.settle()

        #expect(refreshCount == 0)
    }

    /// A second start (a fresh status arriving mid-poll) supersedes the one
    /// before it rather than running both concurrently.
    @Test func startSupersedesAPreviousPoll() async {
        let poller = MacContextAccessPoller(interval: .zero, clock: ManualTestClock())
        var firstPollRefreshCount = 0

        poller.start(refresh: { firstPollRefreshCount += 1 }, isAuthorized: { false })
        var secondPollRefreshCount = 0
        poller.start(
            refresh: { secondPollRefreshCount += 1 },
            isAuthorized: { secondPollRefreshCount == 2 })
        await poller.settle()

        #expect(secondPollRefreshCount == 2)
    }
}

/// A clock whose sleep returns immediately, so these tests run in
/// milliseconds rather than waiting out real seconds.
private struct ManualTestClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    var now: Instant { Instant() }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
    }
}

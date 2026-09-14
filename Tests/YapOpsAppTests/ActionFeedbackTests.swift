// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Testing
@testable import YapOpsApp
@testable import YapOpsCore

@MainActor
struct ActionFeedbackPresentationTests {
    @Test func commandStart_StaysUntilTheOutcomeArrives() {
        let running = ActionFeedbackPresentation.next(
            after: nil,
            event: .commandStarted(title: "computer"))

        #expect(running.title == "computer")
        #expect(running.tone == .working)
        // A process takes as long as it takes; nothing may time it out.
        #expect(running.dismissAfter == nil)
    }

    @Test func commandOutcome_KeepsTheTitleTheStartEstablished() {
        let running = ActionFeedbackPresentation.next(
            after: nil,
            event: .commandStarted(title: "computer"))
        let done = ActionFeedbackPresentation.next(after: running, event: .commandSucceeded)

        #expect(done.title == "computer")
        #expect(done.tone == .success)
        #expect(done.dismissAfter == ActionFeedbackPresentation.successDwell)
    }

    @Test func commandFailure_CarriesTheReasonAndOutlastsASuccess() {
        let running = ActionFeedbackPresentation.next(
            after: nil,
            event: .commandStarted(title: "build"))
        let failed = ActionFeedbackPresentation.next(
            after: running,
            event: .commandFailed(reason: "exited with code 2"))

        #expect(failed.tone == .failure)
        #expect(failed.detail == "exited with code 2")
        #expect(failed.dismissAfter == ActionFeedbackPresentation.failureDwell)
        #expect(ActionFeedbackPresentation.failureDwell > ActionFeedbackPresentation.successDwell)
    }

    @Test func systemAction_ShowsItsOwnSymbolAndName() {
        let locked = ActionFeedbackPresentation.next(
            after: nil,
            event: .systemActionSucceeded(.lockScreen))

        #expect(locked.symbolName == SystemAction.lockScreen.symbolName)
        #expect(locked.title == SystemAction.lockScreen.title)
        #expect(locked.tone == .success)
        #expect(locked.dismissAfter == ActionFeedbackPresentation.successDwell)
    }

    @Test func accessibilityLabel_NamesTheStateColourAloneWouldCarry() {
        let failed = ActionFeedbackPresentation.next(
            after: nil,
            event: .systemActionFailed(.lockScreen, reason: "not permitted"))

        #expect(failed.accessibilityLabel.contains("failed"))
        #expect(failed.accessibilityLabel.contains("not permitted"))
    }
}

@MainActor
struct ActionFeedbackPresenterTests {
    @Test func runningCommand_IsNeverDismissedOnATimer() async {
        let display = RecordingActionFeedbackDisplay()
        let clock = ManualDwell()
        let presenter = ActionFeedbackPresenter(display: display, sleep: clock.sleep)

        presenter.handle(.commandStarted(title: "computer"))

        #expect(display.shown.count == 1)
        #expect(display.hideCount == 0)
        // No dwell was requested at all, so no timer can exist to fire.
        #expect(await clock.requestedDwells().isEmpty)
    }

    @Test func settledOutcome_LeavesAfterItsOwnDwell() async {
        let display = RecordingActionFeedbackDisplay()
        let clock = ManualDwell()
        let presenter = ActionFeedbackPresenter(display: display, sleep: clock.sleep)

        presenter.handle(.systemActionSucceeded(.lockScreen))
        #expect(display.hideCount == 0)

        await clock.releaseAll()
        await waitFor { display.hideCount == 1 }
        #expect(await clock.requestedDwells() == [ActionFeedbackPresentation.successDwell])
    }

    @Test func aNewerAction_IsNotTakenAwayByTheOlderOnesTimer() async {
        let display = RecordingActionFeedbackDisplay()
        let clock = ManualDwell()
        let presenter = ActionFeedbackPresenter(display: display, sleep: clock.sleep)

        presenter.handle(.systemActionSucceeded(.lockScreen))
        // A second action lands before the first one's dwell expires.
        presenter.handle(.commandStarted(title: "computer"))
        await clock.releaseAll()

        // The stale timer must not hide the command that replaced it.
        await waitFor { display.shown.count == 2 }
        #expect(display.hideCount == 0)
        #expect(display.shown.last?.tone == .working)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition was not satisfied")
    }
}

@MainActor
final class RecordingActionFeedbackDisplay: ActionFeedbackDisplaying {
    private(set) var shown: [ActionFeedbackPresentation] = []
    private(set) var hideCount = 0

    func show(_ presentation: ActionFeedbackPresentation) { shown.append(presentation) }
    func hide() { hideCount += 1 }
}

/// Hands out dwells that only finish when the test says so, so timing is a
/// decision the test makes rather than a duration it waits out.
actor ManualDwell {
    private var dwells: [Duration] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Released once, then stays released. The presenter registers its dwell
    /// from a task, so the test cannot know whether it has reached the clock
    /// yet; latching means the release works whichever order they happen in.
    private var isReleased = false

    nonisolated var sleep: ActionFeedbackPresenter.Sleep {
        { [self] duration in await record(duration) }
    }

    private func record(_ duration: Duration) async {
        dwells.append(duration)
        guard !isReleased else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func requestedDwells() -> [Duration] { dwells }

    func releaseAll() {
        isReleased = true
        let resuming = waiting
        waiting.removeAll()
        for continuation in resuming { continuation.resume() }
    }
}

/// The presenter is only useful if the coordinator's events actually reach it,
/// and if the surface gets out of the way when capture wants the same spot.
@MainActor
struct AppModelActionFeedbackWiringTests {
    @Test func coordinatorFeedback_ReachesTheSurface() async throws {
        let fixture = try AppModelTests.Fixture()
        await fixture.model.start()

        fixture.model.coordinator.onActionFeedback?(.systemActionSucceeded(.lockScreen))

        #expect(fixture.actionFeedback.shown.count == 1)
        #expect(fixture.actionFeedback.shown.first?.title == SystemAction.lockScreen.title)
    }

    @Test func newCapture_ClearsAStillRunningCommandsSurface() async throws {
        let fixture = try AppModelTests.Fixture()
        await fixture.model.start()
        fixture.model.coordinator.onActionFeedback?(.commandStarted(title: "computer"))
        #expect(fixture.actionFeedback.hideCount == 0)

        // A running command has no dwell, so only capture can clear it.
        fixture.model.coordinator.onStateChange?(.capturing)

        #expect(fixture.actionFeedback.hideCount == 1)
    }
}

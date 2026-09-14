// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import YapOpsCore

/// Shows a command or system action's progress, then takes it away.
@MainActor
protocol ActionFeedbackDisplaying: AnyObject {
    /// - Parameter handoff: Where the recording overlay just was, so the
    ///   surface can grow out of it rather than appear beside it.
    func show(_ presentation: ActionFeedbackPresentation, from handoff: RecordingOverlayHandoff?)
    func hide()
}

/// Drives the feedback surface from coordinator events.
///
/// Two things live here rather than in the view. The surface's subject
/// survives across events, because only `commandStarted` names the command and
/// the outcome arrives separately. And dismissal is timed, not triggered: a
/// command holds the surface for as long as its process runs, while a settled
/// outcome dwells and leaves on its own.
///
/// A newer event always supersedes a pending dismissal, so a fast second
/// action cannot be taken off screen by the timer belonging to the one before
/// it.
@MainActor
final class ActionFeedbackPresenter {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let display: any ActionFeedbackDisplaying
    private let sleep: Sleep
    private var current: ActionFeedbackPresentation?
    private var dismissal: Task<Void, Never>?

    /// - Parameters:
    ///   - display: The surface to drive.
    ///   - sleep: How the dwell is waited out; injected so tests need no clock.
    init(
        display: any ActionFeedbackDisplaying,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.display = display
        self.sleep = sleep
    }

    /// Presents one coordinator event.
    ///
    /// - Parameters:
    ///   - event: What the coordinator just reported.
    ///   - handoff: Where the recording overlay just was, carried through so
    ///     the surface can continue from it.
    func handle(_ event: ActionFeedbackEvent, from handoff: RecordingOverlayHandoff? = nil) {
        let next = ActionFeedbackPresentation.next(after: current, event: event)
        current = next
        dismissal?.cancel()
        dismissal = nil
        display.show(next, from: handoff)

        guard let dwell = next.dismissAfter else { return }
        dismissal = Task { [weak self, sleep] in
            try? await sleep(dwell)
            guard !Task.isCancelled else { return }
            self?.dismissIfUnchanged(next)
        }
    }

    /// Takes the surface away immediately, cancelling any pending dwell.
    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        current = nil
        display.hide()
    }

    /// Only the moment that scheduled this dwell may end it. A newer event
    /// replaces `current`, and the older timer must then do nothing.
    private func dismissIfUnchanged(_ scheduled: ActionFeedbackPresentation) {
        guard current == scheduled else { return }
        current = nil
        dismissal = nil
        display.hide()
    }
}

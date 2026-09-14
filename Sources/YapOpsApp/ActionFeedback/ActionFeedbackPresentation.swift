// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import YapOpsCore

/// What the feedback surface shows for one moment of a command or system
/// action, and how long it stays.
///
/// Mapping happens once, here, so the symbol, wording, tone and dwell cannot
/// drift between the surface and its accessibility description.
struct ActionFeedbackPresentation: Equatable {
    /// How the moment reads at a glance.
    enum Tone: Equatable {
        /// The process is still running and its outcome is unknown.
        case working
        /// The action completed.
        case success
        /// The action failed, and the reason is worth a moment to read.
        case failure
    }

    /// A completed action is an acknowledgement, not a notification; it should
    /// be gone before it becomes something to dismiss.
    static let successDwell = Duration.seconds(2)
    /// A failure carries a reason, so it outlasts a success by enough to read
    /// one line without inviting the user to go and click something.
    static let failureDwell = Duration.seconds(4)

    /// The SF Symbol standing in for the action.
    let symbolName: String
    /// The action's own name — a wake phrase, or what the system action does.
    let title: String
    /// Why it failed, when it did.
    let detail: String?
    let tone: Tone
    /// How long this stays on screen, or `nil` to stay until the next event.
    let dismissAfter: Duration?

    /// Every command looks the same at a glance, so it borrows the symbol for
    /// running something rather than inventing one per profile.
    private static let commandSymbol = "terminal"

    /// Derives the next presentation from an event.
    ///
    /// Only `commandStarted` names the command, because a wake phrase does not
    /// change while its process runs. The title is carried forward from the
    /// moment being replaced so the surface does not have to re-identify
    /// itself, and falls back to a generic name if an outcome somehow arrives
    /// without a start.
    ///
    /// - Parameters:
    ///   - current: The moment being replaced, if the surface is showing one.
    ///   - event: What the coordinator just reported.
    static func next(
        after current: ActionFeedbackPresentation?,
        event: ActionFeedbackEvent
    ) -> ActionFeedbackPresentation {
        switch event {
        case .commandStarted(let title):
            ActionFeedbackPresentation(
                symbolName: commandSymbol,
                title: title,
                detail: nil,
                tone: .working,
                dismissAfter: nil)
        case .commandSucceeded:
            ActionFeedbackPresentation(
                symbolName: commandSymbol,
                title: current?.title ?? "Command",
                detail: nil,
                tone: .success,
                dismissAfter: successDwell)
        case .commandFailed(let reason):
            ActionFeedbackPresentation(
                symbolName: commandSymbol,
                title: current?.title ?? "Command",
                detail: reason,
                tone: .failure,
                dismissAfter: failureDwell)
        case .systemActionSucceeded(let action):
            ActionFeedbackPresentation(
                symbolName: action.symbolName,
                title: action.title,
                detail: nil,
                tone: .success,
                dismissAfter: successDwell)
        case .systemActionFailed(let action, let reason):
            ActionFeedbackPresentation(
                symbolName: action.symbolName,
                title: action.title,
                detail: reason,
                tone: .failure,
                dismissAfter: failureDwell)
        }
    }

    /// The spoken description of this moment, so VoiceOver hears the same
    /// state the symbol and colour show.
    var accessibilityLabel: String {
        switch tone {
        case .working: "\(title), running"
        case .success: "\(title), done"
        case .failure: detail.map { "\(title), failed. \($0)" } ?? "\(title), failed"
        }
    }
}

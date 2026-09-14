// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

/// One step in the life of a command or system-action run, for transient
/// feedback.
///
/// Agent runs already explain themselves in the conversation panel, and they
/// last long enough to be worth a window. A command or a system action is over
/// in a moment and has no such surface: until now the only trace of "mac lock"
/// was the menu-bar symbol changing and changing back, and a command that
/// exited nonzero looked exactly like one that worked.
///
/// The events say what happened, not how to draw it. A command reports that it
/// started because its outcome is not known until the process exits, and the
/// surface showing it holds the subject across the later events rather than
/// having each one repeat it.
public enum ActionFeedbackEvent: Equatable, Sendable {
    /// A command profile launched a process whose outcome is still unknown.
    ///
    /// - Parameter title: The wake phrase that started it.
    case commandStarted(title: String)
    /// The command's process exited zero.
    case commandSucceeded
    /// The command could not launch, or exited nonzero.
    ///
    /// - Parameter reason: A user-presentable explanation.
    case commandFailed(reason: String)
    /// A macOS action ran.
    case systemActionSucceeded(SystemAction)
    /// A macOS action could not run.
    ///
    /// - Parameters:
    ///   - action: The action that was attempted.
    ///   - reason: A user-presentable explanation.
    case systemActionFailed(SystemAction, reason: String)
}

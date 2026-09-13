// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// Failures that prevent a system action from being performed.
public enum SystemActionError: Error, Equatable, LocalizedError {
    /// Synthesizing the action's key event requires an Accessibility grant.
    case accessibilityNotGranted(SystemAction)
    /// The running system cannot perform the action.
    case unsupported(SystemAction)
    /// The action started but did not complete.
    case failed(SystemAction, String)

    /// A user-presentable explanation of the failure.
    public var errorDescription: String? {
        switch self {
        case let .accessibilityNotGranted(action):
            """
            \(action.title) needs Accessibility access. \
            Enable it in YapOps Settings under Mac context.
            """
        case let .unsupported(action):
            "This Mac cannot perform \(action.title.lowercased())."
        case let .failed(action, reason):
            "\(action.title) failed: \(reason)"
        }
    }
}

/// Performs a macOS system action on behalf of a wake profile.
///
/// The conforming adapter lives in the application layer because every
/// implementation reaches for AppKit, Core Graphics, or a system helper.
public protocol SystemActionPerforming: Sendable {
    /// Performs one action.
    ///
    /// - Parameter action: The macOS operation to perform.
    /// - Throws: A ``SystemActionError`` when the action cannot be performed.
    func perform(_ action: SystemAction) async throws
}

/// A performer that reports every action as unsupported.
///
/// Used as the default dependency so Core tests and previews never reach a real
/// macOS subsystem by accident.
public struct UnavailableSystemActionPerformer: SystemActionPerforming {
    /// Creates a performer that always fails.
    public init() {}

    /// Reports the action as unsupported.
    ///
    /// - Parameter action: The requested operation.
    /// - Throws: ``SystemActionError/unsupported(_:)`` for every action.
    public func perform(_ action: SystemAction) async throws {
        throw SystemActionError.unsupported(action)
    }
}

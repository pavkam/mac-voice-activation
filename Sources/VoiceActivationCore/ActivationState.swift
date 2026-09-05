// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// The coordinator's user-visible speech and execution state.
public enum ActivationState: Equatable, Sendable {
    /// No passive or active speech session is running.
    case disabled
    /// Passive recognition is waiting for an enabled wake phrase.
    case listening
    /// Recognition is collecting a command or conversation utterance.
    case capturing
    /// A command or agent turn is active.
    case executing
    /// Processing stopped because of a user-presentable failure.
    case failed(String)

    /// A concise status label suitable for menus and other compact UI.
    public var label: String {
        switch self {
        case .disabled:
            "Disabled"
        case .listening:
            "Listening"
        case .capturing:
            "Capturing"
        case .executing:
            "Running command"
        case let .failed(message):
            "Error: \(message)"
        }
    }
}

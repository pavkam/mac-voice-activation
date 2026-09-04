// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

public enum ActivationState: Equatable, Sendable {
    case disabled
    case listening
    case capturing
    case executing
    case failed(String)

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

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// An opaque identity that prevents permission responses from crossing agent turns.
public struct AgentTurnToken: Equatable, Hashable, Sendable {
    private let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

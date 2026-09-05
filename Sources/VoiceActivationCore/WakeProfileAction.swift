// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// The operation associated with a wake profile and its push-to-talk shortcut.
public enum WakeProfileAction: Codable, Equatable, Sendable {
    /// Invokes a validated executable template with the recognized transcript.
    case command(CommandTemplate)
    /// Submits the recognized transcript to an ACP-compatible agent harness.
    case agent(AgentHarnessConfiguration)
}

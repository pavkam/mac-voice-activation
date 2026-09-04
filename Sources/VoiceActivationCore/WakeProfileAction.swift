// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

public enum WakeProfileAction: Codable, Equatable, Sendable {
    case command(CommandTemplate)
    case agent(AgentHarnessConfiguration)
}

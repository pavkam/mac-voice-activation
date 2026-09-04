// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

public protocol ACPTransportCreating: Sendable {
    func makeTransport(
        configuration: AgentHarnessConfiguration) async throws -> any ACPTransport
}

public struct ACPProcessTransportFactory: ACPTransportCreating, Sendable {
    public init() {}

    public func makeTransport(
        configuration: AgentHarnessConfiguration) async throws -> any ACPTransport
    {
        try ACPProcessTransport(configuration: configuration)
    }
}

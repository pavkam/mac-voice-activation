// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

/// Creates a fresh transport for one ACP agent process configuration.
public protocol ACPTransportCreating: Sendable {
    /// Creates an unshared transport without starting an ACP session.
    ///
    /// - Parameter configuration: The executable, arguments, and working directory to use.
    /// - Returns: A transport ready to exchange newline-delimited ACP frames.
    /// - Throws: An error when the process cannot be prepared or launched.
    func makeTransport(
        configuration: AgentHarnessConfiguration) async throws -> any ACPTransport
}

/// The production factory that launches ACP transports backed by `Process`.
public struct ACPProcessTransportFactory: ACPTransportCreating, Sendable {
    /// Creates a process-backed transport factory.
    public init() {}

    /// Creates a process-backed transport for the supplied agent configuration.
    ///
    /// - Parameter configuration: The executable, arguments, and working directory to use.
    /// - Returns: A transport connected to the launched child process.
    /// - Throws: ``ACPProcessTransportError`` when launch validation fails.
    public func makeTransport(
        configuration: AgentHarnessConfiguration) async throws -> any ACPTransport
    {
        try ACPProcessTransport(configuration: configuration)
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// A bidirectional, newline-delimited byte transport for an ACP process.
public protocol ACPTransport: Sendable {
    /// Returns the single-consumer stream of bytes received from standard output.
    func output() async -> AsyncThrowingStream<Data, any Error>
    /// Returns diagnostic bytes received from standard error.
    func diagnostics() async -> AsyncStream<Data>
    /// Sends one complete newline-terminated ACP frame.
    ///
    /// - Parameter data: The encoded frame, including its trailing newline.
    /// - Throws: A transport-specific error when the frame is invalid or cannot be written.
    func send(_ data: Data) async throws
    /// Suspends until the child process exits and returns its termination status.
    func waitForExit() async -> Int32
    /// Suspends until both output streams reach their terminal state.
    func waitForDrain() async
    /// Closes output streams to unblock readers during forced cancellation.
    func closeReadStreams() async
    /// Terminates the child process and closes all transport resources.
    func terminate() async
}

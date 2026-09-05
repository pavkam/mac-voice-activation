// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// Incrementally separates newline-delimited ACP frames across arbitrary byte chunks.
public struct ACPLineFramer: Sendable {
    /// The maximum number of payload bytes retained for one frame.
    public static let maximumFrameBytes = 1_048_576

    /// Failures produced while framing the transport byte stream.
    public enum FramingError: Error, Equatable, Sendable {
        /// A frame exceeded ``maximumFrameBytes`` before its newline arrived.
        case oversizedFrame
        /// The stream ended with bytes that were not newline terminated.
        case incompleteFrame
    }

    private var pendingBytes = Data()

    /// Creates an empty incremental framer.
    public init() {}

    /// Appends bytes and returns every complete frame in wire order.
    ///
    /// - Parameter data: The next arbitrary transport chunk.
    /// - Returns: Complete frame payloads without their newline delimiters.
    /// - Throws: ``FramingError/oversizedFrame`` when an unfinished frame exceeds the bound.
    public mutating func append(_ data: Data) throws -> [Data] {
        var frames: [Data] = []

        for byte in data {
            if byte == 0x0A {
                frames.append(pendingBytes)
                pendingBytes.removeAll(keepingCapacity: true)
                continue
            }

            guard pendingBytes.count < Self.maximumFrameBytes else {
                throw FramingError.oversizedFrame
            }
            pendingBytes.append(byte)
        }

        return frames
    }

    /// Validates that the stream ended at a frame boundary.
    ///
    /// - Throws: ``FramingError/incompleteFrame`` when unterminated bytes remain.
    public mutating func finish() throws {
        guard pendingBytes.isEmpty else {
            throw FramingError.incompleteFrame
        }
    }
}

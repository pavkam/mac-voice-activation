// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

public struct ACPLineFramer: Sendable {
    public static let maximumFrameBytes = 1_048_576

    public enum FramingError: Error, Equatable, Sendable {
        case oversizedFrame
        case incompleteFrame
    }

    private var pendingBytes = Data()

    public init() {}

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

    public mutating func finish() throws {
        guard pendingBytes.isEmpty else {
            throw FramingError.incompleteFrame
        }
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// A lossless, sendable representation of the JSON values used by ACP messages.
public enum ACPJSONValue: Codable, Equatable, Sendable {
    /// The JSON `null` value.
    case null
    /// A JSON Boolean value.
    case bool(Bool)
    /// A signed integral JSON number.
    case integer(Int64)
    /// An unsigned integral JSON number that does not fit the signed representation.
    case unsignedInteger(UInt64)
    /// A non-integral JSON number.
    case number(Double)
    /// A JSON string.
    case string(String)
    /// A JSON array whose elements preserve their concrete value kinds.
    case array([ACPJSONValue])
    /// A JSON object keyed by strings.
    case object([String: ACPJSONValue])

    /// Decodes one arbitrary JSON value without erasing integer precision.
    ///
    /// - Parameter decoder: The decoder containing the value.
    /// - Throws: `DecodingError.dataCorrupted` when no JSON representation matches.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ACPJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ACPJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "The value is not valid JSON.")
        }
    }

    /// Encodes the represented value using its original JSON kind.
    ///
    /// - Parameter encoder: The encoder that receives the value.
    /// - Throws: Any error reported by the encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .unsignedInteger(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

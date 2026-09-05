// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// A JSON-RPC identifier in any representation accepted by ACP.
public enum ACPRequestID: Codable, Equatable, Hashable, Sendable {
    /// The explicit JSON `null` identifier.
    case null
    /// A signed 64-bit integer identifier.
    case integer(Int64)
    /// A string identifier.
    case string(String)

    /// Decodes a null, integer, or string JSON-RPC identifier.
    ///
    /// - Parameter decoder: The decoder containing one JSON scalar.
    /// - Throws: ``DecodingError`` when the scalar is not a supported identifier.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A JSON-RPC request ID must be null, an Int64, or a string.")
        }
    }

    /// Encodes the identifier as its corresponding JSON scalar.
    ///
    /// - Parameter encoder: The destination encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case let .integer(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        }
    }
}

/// The structured error payload carried by a JSON-RPC error response.
public struct ACPJSONRPCError: Codable, Equatable, Sendable {
    /// The protocol-defined numeric error code.
    public let code: Int64
    /// The human-readable remote error message.
    public let message: String
    /// Optional structured details supplied by the remote harness.
    public let data: ACPJSONValue?

    /// Creates a JSON-RPC error payload.
    ///
    /// - Parameters:
    ///   - code: The protocol-defined numeric code.
    ///   - message: The remote error message.
    ///   - data: Optional structured error details.
    public init(code: Int64, message: String, data: ACPJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// A validated JSON-RPC 2.0 message exchanged with an ACP harness.
public enum ACPMessage: Codable, Equatable, Sendable {
    /// A client or server request that expects a response with the same identifier.
    case request(id: ACPRequestID, method: String, params: ACPJSONValue?)
    /// A one-way notification without a request identifier.
    case notification(method: String, params: ACPJSONValue?)
    /// A successful response to an earlier request.
    case response(id: ACPRequestID, result: ACPJSONValue)
    /// A failed response to an earlier request.
    case errorResponse(id: ACPRequestID, error: ACPJSONRPCError)

    /// Errors raised when a JSON object is not a valid JSON-RPC 2.0 envelope.
    public enum EnvelopeError: Error, Equatable, Sendable {
        /// The envelope does not declare JSON-RPC version 2.0.
        case unsupportedJSONRPCVersion
        /// The envelope combines or omits members in a way JSON-RPC does not permit.
        case invalidEnvelope
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
        case result
        case error
    }

    /// Decodes and validates one JSON-RPC 2.0 envelope.
    ///
    /// - Parameter decoder: The decoder containing the envelope object.
    /// - Throws: ``EnvelopeError`` or a decoding error when the envelope is invalid.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .jsonrpc) == "2.0" else {
            throw EnvelopeError.unsupportedJSONRPCVersion
        }

        let hasID = container.contains(.id)
        let hasMethod = container.contains(.method)
        let hasResult = container.contains(.result)
        let hasError = container.contains(.error)

        if hasMethod {
            guard !hasResult, !hasError else {
                throw EnvelopeError.invalidEnvelope
            }
            let method = try container.decode(String.self, forKey: .method)
            let params = try container.decodeIfPresent(ACPJSONValue.self, forKey: .params)

            if hasID {
                self = .request(
                    id: try container.decode(ACPRequestID.self, forKey: .id),
                    method: method,
                    params: params)
            } else {
                self = .notification(method: method, params: params)
            }
            return
        }

        guard hasID, hasResult != hasError else {
            throw EnvelopeError.invalidEnvelope
        }
        let id = try container.decode(ACPRequestID.self, forKey: .id)

        if hasResult {
            self = .response(
                id: id,
                result: try container.decode(ACPJSONValue.self, forKey: .result))
        } else {
            self = .errorResponse(
                id: id,
                error: try container.decode(ACPJSONRPCError.self, forKey: .error))
        }
    }

    /// Encodes the message as a JSON-RPC 2.0 envelope.
    ///
    /// - Parameter encoder: The destination encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)

        switch self {
        case let .request(id, method, params):
            try container.encode(id, forKey: .id)
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)
        case let .notification(method, params):
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)
        case let .response(id, result):
            try container.encode(id, forKey: .id)
            try container.encode(result, forKey: .result)
        case let .errorResponse(id, error):
            try container.encode(id, forKey: .id)
            try container.encode(error, forKey: .error)
        }
    }
}

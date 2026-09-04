// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

public enum ACPRequestID: Codable, Equatable, Hashable, Sendable {
    case null
    case integer(Int64)
    case string(String)

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

public struct ACPJSONRPCError: Codable, Equatable, Sendable {
    public let code: Int64
    public let message: String
    public let data: ACPJSONValue?

    public init(code: Int64, message: String, data: ACPJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public enum ACPMessage: Codable, Equatable, Sendable {
    case request(id: ACPRequestID, method: String, params: ACPJSONValue?)
    case notification(method: String, params: ACPJSONValue?)
    case response(id: ACPRequestID, result: ACPJSONValue)
    case errorResponse(id: ACPRequestID, error: ACPJSONRPCError)

    public enum EnvelopeError: Error, Equatable, Sendable {
        case unsupportedJSONRPCVersion
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

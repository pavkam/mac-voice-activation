// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

public struct CommandTemplate: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case executablePath
        case argumentTemplates
    }
    public enum ValidationError: Error, Equatable, LocalizedError {
        case executableMustBeAbsolute
        case missingTranscriptPlaceholder

        public var errorDescription: String? {
            switch self {
            case .executableMustBeAbsolute:
                "The executable path must be absolute."
            case .missingTranscriptPlaceholder:
                "At least one argument must contain {text} or {urlText}."
            }
        }
    }

    public let executablePath: String
    public let argumentTemplates: [String]

    public init(executablePath: String, argumentTemplates: [String]) throws {
        guard executablePath.hasPrefix("/") else {
            throw ValidationError.executableMustBeAbsolute
        }
        guard argumentTemplates.contains(where: {
            $0.contains("{text}") || $0.contains("{urlText}")
        }) else {
            throw ValidationError.missingTranscriptPlaceholder
        }

        self.executablePath = executablePath
        self.argumentTemplates = argumentTemplates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            executablePath: container.decode(String.self, forKey: .executablePath),
            argumentTemplates: container.decode([String].self, forKey: .argumentTemplates))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(executablePath, forKey: .executablePath)
        try container.encode(argumentTemplates, forKey: .argumentTemplates)
    }

    public func expandedArguments(for transcript: String) -> [String] {
        let encoded = Self.encodeQueryValue(transcript)
        return argumentTemplates.map {
            $0.replacingOccurrences(of: "{urlText}", with: encoded)
                .replacingOccurrences(of: "{text}", with: transcript)
        }
    }

    private static func encodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

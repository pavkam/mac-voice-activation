// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// A shell-free executable invocation template containing transcript placeholders.
public struct CommandTemplate: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case executablePath
        case argumentTemplates
    }
    /// Validation failures that make a command template unsafe or unusable.
    public enum ValidationError: Error, Equatable, LocalizedError {
        /// The executable path is not absolute.
        case executableMustBeAbsolute
        /// No argument consumes the recognized transcript.
        case missingTranscriptPlaceholder

        /// A user-presentable explanation of the invalid template.
        public var errorDescription: String? {
            switch self {
            case .executableMustBeAbsolute:
                "The executable path must be absolute."
            case .missingTranscriptPlaceholder:
                "At least one argument must contain {text} or {urlText}."
            }
        }
    }

    /// The absolute path of the executable invoked directly by `Process`.
    public let executablePath: String
    /// Argument templates containing `{text}` or URL-encoded `{urlText}` placeholders.
    public let argumentTemplates: [String]

    /// Creates and validates a command invocation template.
    ///
    /// - Parameters:
    ///   - executablePath: The absolute executable path.
    ///   - argumentTemplates: Direct process arguments containing a transcript placeholder.
    /// - Throws: ``ValidationError`` when either invariant is not satisfied.
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

    /// Decodes and revalidates a persisted command template.
    ///
    /// - Parameter decoder: The decoder containing the persisted values.
    /// - Throws: A decoding or ``ValidationError`` failure.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            executablePath: container.decode(String.self, forKey: .executablePath),
            argumentTemplates: container.decode([String].self, forKey: .argumentTemplates))
    }

    /// Encodes the validated executable and argument templates.
    ///
    /// - Parameter encoder: The encoder that receives the template.
    /// - Throws: Any error reported by the encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(executablePath, forKey: .executablePath)
        try container.encode(argumentTemplates, forKey: .argumentTemplates)
    }

    /// Expands all placeholders without invoking a shell or interpreting metacharacters.
    ///
    /// - Parameter transcript: The recognized command text.
    /// - Returns: The direct argument vector for `Process`.
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

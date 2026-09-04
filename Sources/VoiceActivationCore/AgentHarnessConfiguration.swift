// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

public enum AgentHarnessPreset: String, CaseIterable, Codable, Sendable {
    case cursor
    case codex
    case claude
    case custom
}

public enum AgentPermissionPolicy: String, CaseIterable, Codable, Sendable {
    case ask
    case allowOnce
    case allowAlways
    case reject
    case rejectAlways
}

public struct AgentHarnessConfiguration: Codable, Equatable, Sendable {
    public static let maximumSystemPromptBytes = 8_192

    private enum CodingKeys: String, CodingKey {
        case preset
        case displayName
        case executablePath
        case arguments
        case workingDirectory
        case permissionPolicy
        case systemPrompt
    }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case displayNameRequired
        case executableMustBeAbsolute
        case workingDirectoryMustBeAbsolute
        case systemPromptTooLarge(maximumBytes: Int)

        public var errorDescription: String? {
            switch self {
            case .displayNameRequired:
                "The agent harness display name is required."
            case .executableMustBeAbsolute:
                "The agent harness executable path must be absolute."
            case .workingDirectoryMustBeAbsolute:
                "The agent harness working directory must be absolute."
            case let .systemPromptTooLarge(maximumBytes):
                "The agent system prompt exceeds the \(maximumBytes)-byte UTF-8 limit."
            }
        }
    }

    public let preset: AgentHarnessPreset
    public let displayName: String
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: String
    public let permissionPolicy: AgentPermissionPolicy
    public let systemPrompt: String

    public init(
        preset: AgentHarnessPreset,
        displayName: String,
        executablePath: String,
        arguments: [String],
        workingDirectory: String,
        permissionPolicy: AgentPermissionPolicy,
        systemPrompt: String = "") throws
    {
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDisplayName.isEmpty else {
            throw ValidationError.displayNameRequired
        }
        guard executablePath.hasPrefix("/") else {
            throw ValidationError.executableMustBeAbsolute
        }
        guard workingDirectory.hasPrefix("/") else {
            throw ValidationError.workingDirectoryMustBeAbsolute
        }
        let normalizedSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedSystemPrompt.utf8.count <= Self.maximumSystemPromptBytes else {
            throw ValidationError.systemPromptTooLarge(
                maximumBytes: Self.maximumSystemPromptBytes)
        }

        self.preset = preset
        self.displayName = normalizedDisplayName
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.permissionPolicy = permissionPolicy
        self.systemPrompt = normalizedSystemPrompt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            preset: container.decode(AgentHarnessPreset.self, forKey: .preset),
            displayName: container.decode(String.self, forKey: .displayName),
            executablePath: container.decode(String.self, forKey: .executablePath),
            arguments: container.decode([String].self, forKey: .arguments),
            workingDirectory: container.decode(String.self, forKey: .workingDirectory),
            permissionPolicy: container.decode(AgentPermissionPolicy.self, forKey: .permissionPolicy),
            systemPrompt: container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? "")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preset, forKey: .preset)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(executablePath, forKey: .executablePath)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(permissionPolicy, forKey: .permissionPolicy)
        try container.encode(systemPrompt, forKey: .systemPrompt)
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// A known ACP harness whose executable and arguments can be suggested by the app.
public enum AgentHarnessPreset: String, CaseIterable, Codable, Sendable {
    /// Cursor's ACP-compatible command-line agent.
    case cursor
    /// OpenAI Codex's ACP-compatible command-line agent.
    case codex
    /// Anthropic Claude's ACP-compatible command-line agent.
    case claude
    /// A user-supplied ACP-compatible executable.
    case custom
}

/// The default answer applied when an agent asks to run a privileged operation.
public enum AgentPermissionPolicy: String, CaseIterable, Codable, Sendable {
    /// Always surface the permission request for an explicit answer.
    case ask
    /// Allow the individual operation automatically.
    case allowOnce
    /// Choose the harness option that persistently allows matching operations.
    case allowAlways
    /// Reject the individual operation automatically.
    case reject
    /// Choose the harness option that persistently rejects matching operations.
    case rejectAlways
}

/// A validated, persistable recipe for starting and configuring an ACP harness.
public struct AgentHarnessConfiguration: Codable, Equatable, Sendable {
    /// The maximum UTF-8 size accepted for a profile-specific system prompt.
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

    /// Errors that prevent a harness configuration from being safe to launch.
    public enum ValidationError: Error, Equatable, LocalizedError {
        /// The trimmed display name is empty.
        case displayNameRequired
        /// The executable path is not absolute.
        case executableMustBeAbsolute
        /// The working-directory path is not absolute.
        case workingDirectoryMustBeAbsolute
        /// The system prompt exceeds the bounded UTF-8 size.
        case systemPromptTooLarge(maximumBytes: Int)

        /// A user-presentable explanation of the validation failure.
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

    /// The known harness family, or ``AgentHarnessPreset/custom``.
    public let preset: AgentHarnessPreset
    /// The name shown in Settings and conversation chrome.
    public let displayName: String
    /// The absolute executable path launched without a shell.
    public let executablePath: String
    /// The exact arguments supplied to the executable.
    public let arguments: [String]
    /// The absolute working directory inherited by the harness process.
    public let workingDirectory: String
    /// The default permission-answer policy for this profile.
    public let permissionPolicy: AgentPermissionPolicy
    /// Optional profile-specific instructions prepended to user prompts.
    public let systemPrompt: String

    /// Creates and validates a harness launch configuration.
    ///
    /// - Parameters:
    ///   - preset: The known harness family.
    ///   - displayName: The user-visible harness name.
    ///   - executablePath: The absolute path of the executable.
    ///   - arguments: Arguments passed without shell interpretation.
    ///   - workingDirectory: The absolute process working directory.
    ///   - permissionPolicy: The default response to permission requests.
    ///   - systemPrompt: Optional profile-specific agent instructions.
    /// - Throws: ``ValidationError`` when a required value is invalid or oversized.
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

    /// Decodes and validates a persisted harness configuration.
    ///
    /// - Parameter decoder: The decoder containing the persisted configuration.
    /// - Throws: A decoding or ``ValidationError`` value for invalid persisted data.
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

    /// Encodes the validated harness configuration for persistence.
    ///
    /// - Parameter encoder: The destination encoder.
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

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// The observable completion state of a direct command invocation.
public struct CommandResult: Equatable, Sendable {
    /// The process termination status, which is zero for successful results.
    public let terminationStatus: Int32

    /// Creates a result for a completed child process.
    ///
    /// - Parameter terminationStatus: The status reported by the operating system.
    public init(terminationStatus: Int32) {
        self.terminationStatus = terminationStatus
    }
}

/// Failures that prevent a direct command from completing successfully.
public enum CommandRunnerError: Error, Equatable, LocalizedError {
    /// The configured executable is absent or lacks execute permission.
    case executableIsNotRunnable(String)
    /// Foundation could not launch the child process.
    case launchFailed(String)
    /// The child process exited with a nonzero status.
    case nonzeroExit(Int32)

    /// A user-presentable explanation of the command failure.
    public var errorDescription: String? {
        switch self {
        case .executableIsNotRunnable(let path):
            "The executable is missing or not runnable: \(path)"
        case .launchFailed(let message):
            "The command could not start: \(message)"
        case .nonzeroExit(let status):
            "The command exited with status \(status)."
        }
    }
}

/// Executes validated command templates asynchronously.
public protocol CommandRunning: Sendable {
    /// Runs one transcript-expanded command and waits for process termination.
    ///
    /// - Parameters:
    ///   - template: The validated direct-process template.
    ///   - transcript: The recognized text to substitute into its arguments.
    /// - Returns: The successful zero-status result.
    /// - Throws: ``CommandRunnerError`` when validation, launch, or execution fails.
    func run(template: CommandTemplate, transcript: String) async throws -> CommandResult
}

/// The production direct-process command executor.
public struct CommandRunner: CommandRunning, Sendable {
    private let diagnostics: any VoiceActivationDiagnosticRecording

    /// Creates a command runner with diagnostic event recording.
    ///
    /// - Parameter diagnostics: The privacy-safe recorder for lifecycle metadata.
    public init(
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.diagnostics = diagnostics
    }

    /// Runs a command without shell expansion and discards its standard streams.
    ///
    /// - Parameters:
    ///   - template: The validated executable and argument template.
    ///   - transcript: The recognized text used to expand placeholders.
    /// - Returns: A result after a zero-status exit.
    /// - Throws: ``CommandRunnerError`` for an unrunnable executable, launch failure, or nonzero exit.
    public func run(template: CommandTemplate, transcript: String) async throws -> CommandResult {
        let runID = UUID().uuidString
        let startedAtUptime = DispatchTime.now().uptimeNanoseconds
        diagnostics.record(
            category: .command,
            event: "command.run_requested",
            fields: [
                "command_run_id": runID,
                "executable_path": template.executablePath,
                "argument_count": String(template.argumentTemplates.count),
                "input_character_count": String(transcript.count),
            ])
        guard FileManager.default.isExecutableFile(atPath: template.executablePath) else {
            diagnostics.record(
                category: .command,
                event: "command.run_rejected",
                level: .error,
                fields: [
                    "command_run_id": runID,
                    "reason": "executable_not_runnable",
                ])
            throw CommandRunnerError.executableIsNotRunnable(template.executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: template.executablePath)
        process.arguments = template.expandedArguments(for: transcript)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { completed in
                continuation.resume(returning: completed.terminationStatus)
            }

            do {
                try process.run()
                diagnostics.record(
                    category: .command,
                    event: "command.process_started",
                    fields: [
                        "command_run_id": runID,
                        "process_id": String(process.processIdentifier),
                    ])
            } catch {
                process.terminationHandler = nil
                diagnostics.record(
                    category: .command,
                    event: "command.process_start_failed",
                    level: .error,
                    fields: [
                        "command_run_id": runID,
                        "error_type": String(describing: type(of: error)),
                    ])
                continuation.resume(
                    throwing: CommandRunnerError.launchFailed(error.localizedDescription))
            }
        }

        guard status == 0 else {
            diagnostics.record(
                category: .command,
                event: "command.process_finished",
                level: .error,
                fields: [
                    "command_run_id": runID,
                    "termination_status": String(status),
                    "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
                ])
            throw CommandRunnerError.nonzeroExit(status)
        }
        diagnostics.record(
            category: .command,
            event: "command.process_finished",
            fields: [
                "command_run_id": runID,
                "termination_status": String(status),
                "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
            ])
        return CommandResult(terminationStatus: status)
    }

    private static func elapsedMilliseconds(since start: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= start else { return 0 }
        return (now - start) / 1_000_000
    }
}

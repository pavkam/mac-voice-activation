// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

public struct CommandResult: Equatable, Sendable {
    public let terminationStatus: Int32

    public init(terminationStatus: Int32) {
        self.terminationStatus = terminationStatus
    }
}

public enum CommandRunnerError: Error, Equatable, LocalizedError {
    case executableIsNotRunnable(String)
    case launchFailed(String)
    case nonzeroExit(Int32)

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

public protocol CommandRunning: Sendable {
    func run(template: CommandTemplate, transcript: String) async throws -> CommandResult
}

public struct CommandRunner: CommandRunning, Sendable {
    private let diagnostics: any VoiceActivationDiagnosticRecording

    public init(
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.diagnostics = diagnostics
    }

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

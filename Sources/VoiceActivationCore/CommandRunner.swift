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
        case let .executableIsNotRunnable(path):
            "The executable is missing or not runnable: \(path)"
        case let .launchFailed(message):
            "The command could not start: \(message)"
        case let .nonzeroExit(status):
            "The command exited with status \(status)."
        }
    }
}

public protocol CommandRunning: Sendable {
    func run(template: CommandTemplate, transcript: String) async throws -> CommandResult
}

public struct CommandRunner: CommandRunning, Sendable {
    public init() {}

    public func run(template: CommandTemplate, transcript: String) async throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: template.executablePath) else {
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
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: CommandRunnerError.launchFailed(error.localizedDescription))
            }
        }

        guard status == 0 else {
            throw CommandRunnerError.nonzeroExit(status)
        }
        return CommandResult(terminationStatus: status)
    }
}

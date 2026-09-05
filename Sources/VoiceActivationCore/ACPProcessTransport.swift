// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// Failures while launching or communicating with a local ACP process.
public enum ACPProcessTransportError: Error, Equatable, LocalizedError, Sendable {
    /// The configured executable is absent or lacks execute permission.
    case executableIsNotRunnable(String)
    /// A write was not exactly one newline-terminated ACP frame.
    case invalidFrame
    /// Foundation or process setup failed before the child could run.
    case launchFailed(String)
    /// The process input stream can no longer accept frames.
    case transportClosed

    /// A user-presentable explanation of the process transport failure.
    public var errorDescription: String? {
        switch self {
        case .executableIsNotRunnable(let path):
            "The agent executable is missing or not runnable: \(path)"
        case .invalidFrame:
            "An ACP transport write must contain exactly one newline-terminated frame."
        case .launchFailed(let message):
            "The agent process could not start: \(message)"
        case .transportClosed:
            "The agent process transport is closed."
        }
    }
}

enum ACPProcessTransportReadStream: Hashable, Sendable {
    case output
    case diagnostic
}

struct ACPProcessTransportTestingHooks: Sendable {
    let beforeYield: @Sendable (ACPProcessTransportReadStream) -> Void
    let beforeDrainWaiterRegistration: @Sendable () -> Void

    init(
        beforeYield: @escaping @Sendable (ACPProcessTransportReadStream) -> Void = { _ in },
        beforeDrainWaiterRegistration: @escaping @Sendable () -> Void = {}
    ) {
        self.beforeYield = beforeYield
        self.beforeDrainWaiterRegistration = beforeDrainWaiterRegistration
    }
}

/// A newline-framed ACP transport backed by a directly launched local process.
public final class ACPProcessTransport: ACPTransport, @unchecked Sendable {
    private let state: ACPProcessTransportState

    /// Launches the process described by a validated harness configuration.
    ///
    /// - Parameter configuration: The executable, arguments, working directory, and prompt setup.
    /// - Throws: ``ACPProcessTransportError`` when process setup or launch fails.
    public convenience init(configuration: AgentHarnessConfiguration) throws {
        try self.init(
            executableURL: URL(fileURLWithPath: configuration.executablePath),
            arguments: configuration.arguments,
            currentDirectoryURL: URL(fileURLWithPath: configuration.workingDirectory),
            environment: try Self.processEnvironment(for: configuration),
            testingHooks: ACPProcessTransportTestingHooks())
    }

    /// Launches a process with explicit paths and the current process environment.
    ///
    /// - Parameters:
    ///   - executableURL: The absolute executable file URL.
    ///   - arguments: Arguments passed directly without shell expansion.
    ///   - currentDirectoryURL: The absolute child-process working directory.
    /// - Throws: ``ACPProcessTransportError`` when process setup or launch fails.
    public convenience init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL
    ) throws {
        try self.init(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: ProcessInfo.processInfo.environment,
            testingHooks: ACPProcessTransportTestingHooks())
    }

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        testingHooks: ACPProcessTransportTestingHooks,
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    )
        throws
    {
        let transportID = UUID()
        diagnostics.record(
            category: .acp,
            event: "acp_transport.launch_requested",
            fields: [
                "transport_id": transportID.uuidString,
                "executable_path": executableURL.path,
                "argument_count": String(arguments.count),
                "working_directory": currentDirectoryURL.path,
            ])
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            diagnostics.record(
                category: .acp,
                event: "acp_transport.launch_rejected",
                level: .error,
                fields: [
                    "transport_id": transportID.uuidString,
                    "reason": "executable_not_runnable",
                ])
            throw ACPProcessTransportError.executableIsNotRunnable(executableURL.path)
        }

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let inputDescriptor = standardInput.fileHandleForWriting.fileDescriptor
        guard Darwin.fcntl(inputDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            let message = String(cString: Darwin.strerror(errno))
            throw ACPProcessTransportError.launchFailed(message)
        }
        let inputFlags = Darwin.fcntl(inputDescriptor, F_GETFL)
        guard inputFlags >= 0,
            Darwin.fcntl(inputDescriptor, F_SETFL, inputFlags | O_NONBLOCK) == 0
        else {
            let message = String(cString: Darwin.strerror(errno))
            throw ACPProcessTransportError.launchFailed(message)
        }
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = Self.environment(
            environment,
            includingExecutableDirectoryFor: executableURL)
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        let state = ACPProcessTransportState(
            process: process,
            standardInput: standardInput,
            standardOutput: standardOutput,
            standardError: standardError,
            testingHooks: testingHooks,
            transportID: transportID,
            diagnosticsRecorder: diagnostics)
        self.state = state
        state.installHandlers()

        do {
            try process.run()
            diagnostics.record(
                category: .acp,
                event: "acp_transport.launched",
                fields: [
                    "transport_id": transportID.uuidString,
                    "process_id": String(process.processIdentifier),
                ])
        } catch {
            state.finishFailedLaunch()
            diagnostics.record(
                category: .acp,
                event: "acp_transport.launch_failed",
                level: .error,
                fields: [
                    "transport_id": transportID.uuidString,
                    "error_type": String(describing: type(of: error)),
                ])
            throw ACPProcessTransportError.launchFailed(error.localizedDescription)
        }
    }

    private static func processEnvironment(
        for configuration: AgentHarnessConfiguration
    ) throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        guard configuration.preset == .codex, !configuration.systemPrompt.isEmpty else {
            return environment
        }

        var codexConfiguration: [String: Any] = [:]
        if let existingValue = environment["CODEX_CONFIG"], !existingValue.isEmpty {
            guard let data = existingValue.data(using: .utf8),
                let existingObject = try? JSONSerialization.jsonObject(with: data),
                let existingConfiguration = existingObject as? [String: Any]
            else {
                throw ACPProcessTransportError.launchFailed(
                    "CODEX_CONFIG must contain a JSON object before a Codex system prompt can be applied."
                )
            }
            codexConfiguration = existingConfiguration
        }
        codexConfiguration["developer_instructions"] = """
            Voice Activation presentation contract:
            \(ACPAgentInstruction.responseStyle)

            Profile-specific system instruction:
            \(configuration.systemPrompt)
            """
        let encodedConfiguration = try JSONSerialization.data(
            withJSONObject: codexConfiguration,
            options: [.sortedKeys])
        guard let encodedValue = String(data: encodedConfiguration, encoding: .utf8) else {
            throw ACPProcessTransportError.launchFailed(
                "The Codex system prompt could not be encoded as UTF-8.")
        }
        environment["CODEX_CONFIG"] = encodedValue
        return environment
    }

    private static func environment(
        _ inheritedEnvironment: [String: String],
        includingExecutableDirectoryFor executableURL: URL
    ) -> [String: String] {
        var environment = inheritedEnvironment
        let executableDirectory = executableURL.deletingLastPathComponent().path
        let inheritedPath = environment["PATH"] ?? ""
        let pathDirectories = inheritedPath.split(
            separator: ":",
            omittingEmptySubsequences: true
        ).map(String.init)
        environment["PATH"] =
            ([executableDirectory]
            + pathDirectories.filter { $0 != executableDirectory })
            .joined(separator: ":")
        return environment
    }

    /// Returns the single-consumer stream of newline-framed standard output chunks.
    public func output() async -> AsyncThrowingStream<Data, any Error> {
        state.output
    }

    /// Returns the single-consumer stream of raw standard-error diagnostic chunks.
    public func diagnostics() async -> AsyncStream<Data> {
        state.diagnostics
    }

    /// Queues exactly one newline-terminated ACP frame for ordered nonblocking output.
    ///
    /// - Parameter data: One complete frame including its trailing newline.
    /// - Throws: ``ACPProcessTransportError`` when the frame is invalid or transport closed.
    public func send(_ data: Data) async throws {
        guard data.last == 0x0A, !data.dropLast().contains(0x0A) else {
            VoiceActivationDiagnostics.shared.record(
                category: .acp,
                event: "acp_transport.frame_rejected",
                level: .warning,
                fields: ["byte_count": String(data.count)])
            throw ACPProcessTransportError.invalidFrame
        }
        try state.send(data)
    }

    /// Waits for process termination and returns its exit status.
    public func waitForExit() async -> Int32 {
        await state.waitForExit()
    }

    /// Waits until both process read streams reach their terminal state.
    public func waitForDrain() async {
        await state.waitForDrain()
    }

    /// Stops accepting read callbacks and finishes both consumer streams.
    public func closeReadStreams() async {
        state.closeReadStreams()
    }

    /// Closes process input and requests bounded cooperative process termination.
    public func terminate() async {
        state.terminate()
    }

    var hasPendingForcedTerminationForTesting: Bool {
        state.hasPendingForcedTermination
    }

    var pendingDrainWaiterCountForTesting: Int {
        state.pendingDrainWaiterCount
    }
}

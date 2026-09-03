import Darwin
import Foundation

public enum ACPProcessTransportError: Error, Equatable, LocalizedError, Sendable {
    case executableIsNotRunnable(String)
    case invalidFrame
    case launchFailed(String)
    case transportClosed

    public var errorDescription: String? {
        switch self {
        case let .executableIsNotRunnable(path):
            "The agent executable is missing or not runnable: \(path)"
        case .invalidFrame:
            "An ACP transport write must contain exactly one newline-terminated frame."
        case let .launchFailed(message):
            "The agent process could not start: \(message)"
        case .transportClosed:
            "The agent process transport is closed."
        }
    }
}

public final class ACPProcessTransport: ACPTransport, @unchecked Sendable {
    private let state: ACPProcessTransportState

    public convenience init(configuration: AgentHarnessConfiguration) throws {
        try self.init(
            executableURL: URL(fileURLWithPath: configuration.executablePath),
            arguments: configuration.arguments,
            currentDirectoryURL: URL(fileURLWithPath: configuration.workingDirectory))
    }

    public init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL) throws
    {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ACPProcessTransportError.executableIsNotRunnable(executableURL.path)
        }

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        let state = ACPProcessTransportState(
            process: process,
            standardInput: standardInput,
            standardOutput: standardOutput,
            standardError: standardError)
        self.state = state
        state.installHandlers()

        do {
            try process.run()
        } catch {
            state.finishFailedLaunch()
            throw ACPProcessTransportError.launchFailed(error.localizedDescription)
        }
    }

    public func output() async -> AsyncThrowingStream<Data, any Error> {
        state.output
    }

    public func diagnostics() async -> AsyncStream<Data> {
        state.diagnostics
    }

    public func send(_ data: Data) async throws {
        guard data.last == 0x0A, !data.dropLast().contains(0x0A) else {
            throw ACPProcessTransportError.invalidFrame
        }
        try state.send(data)
    }

    public func waitForExit() async -> Int32 {
        await state.waitForExit()
    }

    public func terminate() async {
        state.terminate()
    }
}

private final class ACPProcessTransportState: @unchecked Sendable {
    let output: AsyncThrowingStream<Data, any Error>
    let diagnostics: AsyncStream<Data>

    private static let failedLaunchStatus: Int32 = -1
    private static let forcedTerminationDelay = DispatchTimeInterval.milliseconds(500)

    private let process: Process
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private let diagnosticHandle: FileHandle
    private let outputContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let diagnosticContinuation: AsyncStream<Data>.Continuation
    private let stateLock = NSLock()
    private let sendLock = NSLock()
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var terminationWasRequested = false
    private var outputWasFinished = false
    private var diagnosticsWereFinished = false
    private var inputWasClosed = false

    init(
        process: Process,
        standardInput: Pipe,
        standardOutput: Pipe,
        standardError: Pipe)
    {
        self.process = process
        inputHandle = standardInput.fileHandleForWriting
        outputHandle = standardOutput.fileHandleForReading
        diagnosticHandle = standardError.fileHandleForReading

        let outputPair = AsyncThrowingStream<Data, any Error>.makeStream()
        output = outputPair.stream
        outputContinuation = outputPair.continuation

        let diagnosticPair = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingNewest(32))
        diagnostics = diagnosticPair.stream
        diagnosticContinuation = diagnosticPair.continuation
    }

    deinit {
        finishOutput()
        finishDiagnostics()
    }

    func installHandlers() {
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                try? handle.close()
                self?.finishOutput()
                return
            }
            self?.outputContinuation.yield(data)
        }
        diagnosticHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                try? handle.close()
                self?.finishDiagnostics()
                return
            }
            self?.diagnosticContinuation.yield(data)
        }
        process.terminationHandler = { [weak self] completedProcess in
            self?.processExited(status: completedProcess.terminationStatus)
        }
    }

    func finishFailedLaunch() {
        process.terminationHandler = nil
        outputHandle.readabilityHandler = nil
        diagnosticHandle.readabilityHandler = nil
        finishExit(status: Self.failedLaunchStatus)
        finishOutput()
        finishDiagnostics()
        closeHandlesAfterExit()
        try? outputHandle.close()
        try? diagnosticHandle.close()
    }

    func send(_ data: Data) throws {
        sendLock.lock()
        defer { sendLock.unlock() }

        let isClosed = stateLock.withLock {
            terminationWasRequested || exitStatus != nil
        }
        guard !isClosed else {
            throw ACPProcessTransportError.transportClosed
        }

        do {
            try inputHandle.write(contentsOf: data)
        } catch {
            throw ACPProcessTransportError.transportClosed
        }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let completedStatus = stateLock.withLock { () -> Int32? in
                if let exitStatus {
                    return exitStatus
                }
                exitWaiters.append(continuation)
                return nil
            }
            if let completedStatus {
                continuation.resume(returning: completedStatus)
            }
        }
    }

    func terminate() {
        let shouldTerminate = stateLock.withLock { () -> Bool in
            guard exitStatus == nil, !terminationWasRequested else {
                return false
            }
            terminationWasRequested = true
            return true
        }
        guard shouldTerminate else {
            return
        }

        let processID = process.processIdentifier
        let wasRunning = process.isRunning
        if wasRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + Self.forcedTerminationDelay
            ) { [weak self] in
                self?.forceTerminationIfNeeded(processID: processID)
            }
        }
    }

    private func forceTerminationIfNeeded(processID: Int32) {
        let needsTermination = stateLock.withLock {
            terminationWasRequested && exitStatus == nil
        }
        if needsTermination {
            _ = Darwin.kill(processID, SIGKILL)
        }
    }

    private func processExited(status: Int32) {
        process.terminationHandler = nil
        finishExit(status: status)
        closeHandlesAfterExit()
    }

    private func finishExit(status: Int32) {
        let waiters = stateLock.withLock { () -> [CheckedContinuation<Int32, Never>] in
            guard exitStatus == nil else {
                return []
            }
            exitStatus = status
            let waiters = exitWaiters
            exitWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: status)
        }
    }

    private func finishOutput() {
        let shouldFinish = stateLock.withLock { () -> Bool in
            guard !outputWasFinished else {
                return false
            }
            outputWasFinished = true
            return true
        }
        if shouldFinish {
            outputContinuation.finish()
        }
    }

    private func finishDiagnostics() {
        let shouldFinish = stateLock.withLock { () -> Bool in
            guard !diagnosticsWereFinished else {
                return false
            }
            diagnosticsWereFinished = true
            return true
        }
        if shouldFinish {
            diagnosticContinuation.finish()
        }
    }

    private func closeHandlesAfterExit() {
        sendLock.lock()
        let shouldCloseInput = stateLock.withLock { () -> Bool in
            guard !inputWasClosed else {
                return false
            }
            inputWasClosed = true
            return true
        }
        if shouldCloseInput {
            try? inputHandle.close()
        }
        sendLock.unlock()
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}

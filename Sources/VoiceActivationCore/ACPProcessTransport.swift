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

enum ACPProcessTransportReadStream: Hashable, Sendable {
    case output
    case diagnostic
}

struct ACPProcessTransportTestingHooks: Sendable {
    let beforeYield: @Sendable (ACPProcessTransportReadStream) -> Void
    let beforeDrainWaiterRegistration: @Sendable () -> Void

    init(
        beforeYield: @escaping @Sendable (ACPProcessTransportReadStream) -> Void = { _ in },
        beforeDrainWaiterRegistration: @escaping @Sendable () -> Void = {})
    {
        self.beforeYield = beforeYield
        self.beforeDrainWaiterRegistration = beforeDrainWaiterRegistration
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

    public convenience init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL) throws
    {
        try self.init(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            testingHooks: ACPProcessTransportTestingHooks())
    }

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        testingHooks: ACPProcessTransportTestingHooks) throws
    {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
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
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        let state = ACPProcessTransportState(
            process: process,
            standardInput: standardInput,
            standardOutput: standardOutput,
            standardError: standardError,
            testingHooks: testingHooks)
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

    public func waitForDrain() async {
        await state.waitForDrain()
    }

    public func closeReadStreams() async {
        state.closeReadStreams()
    }

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
    private let testingHooks: ACPProcessTransportTestingHooks
    private let stateLock = NSLock()
    private let sendLock = NSLock()
    private let outputReadLock = NSLock()
    private let diagnosticReadLock = NSLock()
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var drainWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var terminationWasRequested = false
    private var outputWasFinished = false
    private var diagnosticsWereFinished = false
    private var inputWasClosed = false
    private var forcedTerminationID: UUID?
    private var forcedTerminationWorkItem: DispatchWorkItem?

    var hasPendingForcedTermination: Bool {
        stateLock.withLock { forcedTerminationWorkItem != nil }
    }

    var pendingDrainWaiterCount: Int {
        stateLock.withLock { drainWaiters.count }
    }

    init(
        process: Process,
        standardInput: Pipe,
        standardOutput: Pipe,
        standardError: Pipe,
        testingHooks: ACPProcessTransportTestingHooks)
    {
        self.process = process
        self.testingHooks = testingHooks
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
            self?.readOutput(from: handle)
        }
        diagnosticHandle.readabilityHandler = { [weak self] handle in
            self?.readDiagnostic(from: handle)
        }
        process.terminationHandler = { [weak self] completedProcess in
            self?.processExited(status: completedProcess.terminationStatus)
        }
    }

    func finishFailedLaunch() {
        process.terminationHandler = nil
        finishExit(status: Self.failedLaunchStatus)
        closeHandlesAfterExit()
        closeReadStreams()
    }

    func send(_ data: Data) throws {
        sendLock.lock()
        defer { sendLock.unlock() }

        let isClosed = stateLock.withLock {
            terminationWasRequested || exitStatus != nil || inputWasClosed
        }
        guard !isClosed else {
            throw ACPProcessTransportError.transportClosed
        }

        let didWriteCompleteFrame = data.withUnsafeBytes { bytes -> Bool in
            guard let address = bytes.baseAddress else {
                return false
            }
            var writtenByteCount: Int
            repeat {
                writtenByteCount = Darwin.write(
                    inputHandle.fileDescriptor,
                    address,
                    bytes.count)
            } while writtenByteCount < 0 && errno == EINTR
            return writtenByteCount == bytes.count
        }
        guard didWriteCompleteFrame else {
            closeInputWhileSendLocked()
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

    func waitForDrain() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                testingHooks.beforeDrainWaiterRegistration()
                let shouldResume = stateLock.withLock { () -> Bool in
                    guard !Task.isCancelled,
                          !(outputWasFinished && diagnosticsWereFinished)
                    else {
                        return true
                    }
                    drainWaiters[id] = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.cancelDrainWaiter(id: id)
        }
    }

    func closeReadStreams() {
        outputReadLock.withLock {
            outputHandle.readabilityHandler = nil
            try? outputHandle.close()
            finishOutputWhileReadLocked()
        }
        diagnosticReadLock.withLock {
            diagnosticHandle.readabilityHandler = nil
            try? diagnosticHandle.close()
            finishDiagnosticsWhileReadLocked()
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
            let forcedTerminationID = UUID()
            let workItem = DispatchWorkItem { [weak self, weak process] in
                guard let process else {
                    return
                }
                self?.forceTerminationIfNeeded(
                    id: forcedTerminationID,
                    process: process,
                    processID: processID)
            }
            let shouldSchedule = stateLock.withLock { () -> Bool in
                guard exitStatus == nil else {
                    return false
                }
                self.forcedTerminationID = forcedTerminationID
                forcedTerminationWorkItem = workItem
                return true
            }
            if shouldSchedule {
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + Self.forcedTerminationDelay,
                    execute: workItem)
            }
        }
        closeInput()
    }

    private func forceTerminationIfNeeded(
        id: UUID,
        process expectedProcess: Process,
        processID: Int32)
    {
        let needsTermination = stateLock.withLock {
            terminationWasRequested
                && exitStatus == nil
                && forcedTerminationID == id
                && forcedTerminationWorkItem?.isCancelled == false
        }
        guard needsTermination else {
            return
        }

        let identityIsCurrent = stateLock.withLock {
            exitStatus == nil && forcedTerminationID == id
        }
        guard identityIsCurrent,
              process === expectedProcess,
              expectedProcess.processIdentifier == processID,
              expectedProcess.isRunning
        else {
            return
        }
        _ = Darwin.kill(processID, SIGKILL)
    }

    private func processExited(status: Int32) {
        process.terminationHandler = nil
        finishExit(status: status)
        closeHandlesAfterExit()
    }

    private func finishExit(status: Int32) {
        let result = stateLock.withLock {
            () -> ([CheckedContinuation<Int32, Never>], DispatchWorkItem?) in
            guard exitStatus == nil else {
                return ([], nil)
            }
            exitStatus = status
            let waiters = exitWaiters
            exitWaiters.removeAll()
            let workItem = forcedTerminationWorkItem
            forcedTerminationID = nil
            forcedTerminationWorkItem = nil
            return (waiters, workItem)
        }
        result.1?.cancel()
        for waiter in result.0 {
            waiter.resume(returning: status)
        }
    }

    private func finishOutput() {
        outputReadLock.withLock {
            finishOutputWhileReadLocked()
        }
    }

    private func markOutputFinished() -> (Bool, [CheckedContinuation<Void, Never>]) {
        stateLock.withLock {
            () -> (Bool, [CheckedContinuation<Void, Never>]) in
            guard !outputWasFinished else {
                return (false, [])
            }
            outputWasFinished = true
            return (true, takeDrainWaitersIfFinished())
        }
    }

    private func finishDiagnostics() {
        diagnosticReadLock.withLock {
            finishDiagnosticsWhileReadLocked()
        }
    }

    private func markDiagnosticsFinished() -> (Bool, [CheckedContinuation<Void, Never>]) {
        stateLock.withLock {
            () -> (Bool, [CheckedContinuation<Void, Never>]) in
            guard !diagnosticsWereFinished else {
                return (false, [])
            }
            diagnosticsWereFinished = true
            return (true, takeDrainWaitersIfFinished())
        }
    }

    private func closeHandlesAfterExit() {
        sendLock.lock()
        closeInputWhileSendLocked()
        sendLock.unlock()
    }

    private func closeInput() {
        sendLock.lock()
        closeInputWhileSendLocked()
        sendLock.unlock()
    }

    private func closeInputWhileSendLocked() {
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
    }

    private func readOutput(from handle: FileHandle) {
        outputReadLock.withLock {
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                try? handle.close()
                finishOutputWhileReadLocked()
                return
            }
            testingHooks.beforeYield(.output)
            outputContinuation.yield(data)
        }
    }

    private func readDiagnostic(from handle: FileHandle) {
        diagnosticReadLock.withLock {
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                try? handle.close()
                finishDiagnosticsWhileReadLocked()
                return
            }
            testingHooks.beforeYield(.diagnostic)
            diagnosticContinuation.yield(data)
        }
    }

    private func finishOutputWhileReadLocked() {
        let result = markOutputFinished()
        if result.0 {
            outputContinuation.finish()
        }
        resumeDrainWaiters(result.1)
    }

    private func finishDiagnosticsWhileReadLocked() {
        let result = markDiagnosticsFinished()
        if result.0 {
            diagnosticContinuation.finish()
        }
        resumeDrainWaiters(result.1)
    }

    private func takeDrainWaitersIfFinished() -> [CheckedContinuation<Void, Never>] {
        guard outputWasFinished, diagnosticsWereFinished else {
            return []
        }
        let waiters = Array(drainWaiters.values)
        drainWaiters.removeAll()
        return waiters
    }

    private func resumeDrainWaiters(_ waiters: [CheckedContinuation<Void, Never>]) {
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func cancelDrainWaiter(id: UUID) {
        stateLock.withLock {
            drainWaiters.removeValue(forKey: id)
        }?.resume()
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}

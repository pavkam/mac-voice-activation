// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// Serializes process callbacks, nonblocking writes, stream completion, and termination.
///
/// All mutable state is protected by the internal lock; callbacks never resume
/// continuations while holding it, avoiding re-entrant transport deadlocks.
final class ACPProcessTransportState: @unchecked Sendable {
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
    private let transportID: UUID
    private let diagnosticsRecorder: any VoiceActivationDiagnosticRecording
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
        testingHooks: ACPProcessTransportTestingHooks,
        transportID: UUID,
        diagnosticsRecorder: any VoiceActivationDiagnosticRecording
    ) {
        self.process = process
        self.testingHooks = testingHooks
        self.transportID = transportID
        self.diagnosticsRecorder = diagnosticsRecorder
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
        diagnosticsRecorder.record(
            category: .acp,
            event: "acp_transport.handlers_installed",
            fields: ["transport_id": transportID.uuidString])
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
        diagnosticsRecorder.record(
            category: .acp,
            event: "acp_transport.failed_launch_cleanup",
            fields: ["transport_id": transportID.uuidString])
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
            diagnosticsRecorder.record(
                category: .acp,
                event: "acp_transport.send_rejected",
                level: .warning,
                fields: [
                    "transport_id": transportID.uuidString,
                    "reason": "closed",
                    "byte_count": String(data.count),
                ])
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
            diagnosticsRecorder.record(
                category: .acp,
                event: "acp_transport.send_failed",
                level: .error,
                fields: [
                    "transport_id": transportID.uuidString,
                    "byte_count": String(data.count),
                ])
            throw ACPProcessTransportError.transportClosed
        }
        diagnosticsRecorder.record(
            category: .acp,
            event: "acp_transport.frame_sent",
            level: .debug,
            fields: [
                "transport_id": transportID.uuidString,
                "byte_count": String(data.count),
            ])
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
        diagnosticsRecorder.record(
            category: .acp,
            event: "acp_transport.drain_wait_started",
            level: .debug,
            fields: ["transport_id": transportID.uuidString])
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
        diagnosticsRecorder.record(
            category: .acp,
            event: "acp_transport.read_streams_closing",
            fields: ["transport_id": transportID.uuidString])
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
            diagnosticsRecorder.record(
                category: .acp,
                event: "acp_transport.terminate_ignored",
                level: .debug,
                fields: ["transport_id": transportID.uuidString])
            return
        }

        let processID = process.processIdentifier
        let wasRunning = process.isRunning
        diagnosticsRecorder.record(
            category: .acp,
            event: "acp_transport.terminate_requested",
            fields: [
                "transport_id": transportID.uuidString,
                "process_id": String(processID),
                "was_running": String(wasRunning),
            ])
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
        processID: Int32
    ) {
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
        diagnosticsRecorder.record(
            category: .acp,
            event: "acp_transport.force_terminated",
            level: .warning,
            fields: [
                "transport_id": transportID.uuidString,
                "process_id": String(processID),
            ])
    }

    private func processExited(status: Int32) {
        diagnosticsRecorder.record(
            category: .acp,
            event: "acp_transport.process_exited",
            level: status == 0 ? .info : .error,
            fields: [
                "transport_id": transportID.uuidString,
                "process_id": String(process.processIdentifier),
                "termination_status": String(status),
            ])
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
            diagnosticsRecorder.record(
                category: .acp,
                event: "acp_transport.output_received",
                level: .debug,
                fields: [
                    "transport_id": transportID.uuidString,
                    "byte_count": String(data.count),
                ])
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
            diagnosticsRecorder.record(
                category: .acp,
                event: "acp_transport.diagnostic_received",
                level: .debug,
                fields: [
                    "transport_id": transportID.uuidString,
                    "byte_count": String(data.count),
                ])
            testingHooks.beforeYield(.diagnostic)
            diagnosticContinuation.yield(data)
        }
    }

    private func finishOutputWhileReadLocked() {
        let result = markOutputFinished()
        if result.0 {
            outputContinuation.finish()
            diagnosticsRecorder.record(
                category: .acp,
                event: "acp_transport.output_finished",
                fields: ["transport_id": transportID.uuidString])
        }
        resumeDrainWaiters(result.1)
    }

    private func finishDiagnosticsWhileReadLocked() {
        let result = markDiagnosticsFinished()
        if result.0 {
            diagnosticContinuation.finish()
            diagnosticsRecorder.record(
                category: .acp,
                event: "acp_transport.diagnostic_finished",
                fields: ["transport_id": transportID.uuidString])
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
        if !waiters.isEmpty {
            diagnosticsRecorder.record(
                category: .acp,
                event: "acp_transport.drain_wait_finished",
                level: .debug,
                fields: [
                    "transport_id": transportID.uuidString,
                    "waiter_count": String(waiters.count),
                ])
        }
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

extension NSLock {
    fileprivate func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}

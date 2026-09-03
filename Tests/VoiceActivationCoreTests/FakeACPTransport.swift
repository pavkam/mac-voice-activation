import Foundation
@testable import VoiceActivationCore

enum FakeACPTransportError: Error, Equatable, Sendable {
    case invalidOutboundFrame
    case outputFailed
}

actor FakeACPTransport: ACPTransport {
    private let outputStream: AsyncThrowingStream<Data, any Error>
    private let outputContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let diagnosticStream: AsyncStream<Data>
    private let diagnosticContinuation: AsyncStream<Data>.Continuation
    private var sentMessages: [ACPMessage] = []
    private var rawFrames: [Data] = []
    private var unobservedMessages: [ACPMessage] = []
    private var sentMessageWaiters: [CheckedContinuation<ACPMessage, Never>] = []
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var exitStatus: Int32?
    private var terminationCount = 0
    private var outputCallCount = 0
    private var shouldSuspendNextSend = false
    private var sendIsSuspended = false
    private var suspendedSendContinuation: CheckedContinuation<Void, Never>?
    private var suspendedSendWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        let output = AsyncThrowingStream<Data, any Error>.makeStream()
        outputStream = output.stream
        outputContinuation = output.continuation

        let diagnostics = AsyncStream<Data>.makeStream()
        diagnosticStream = diagnostics.stream
        diagnosticContinuation = diagnostics.continuation
    }

    func output() async -> AsyncThrowingStream<Data, any Error> {
        outputCallCount += 1
        return outputStream
    }

    func diagnostics() async -> AsyncStream<Data> {
        diagnosticStream
    }

    func send(_ data: Data) async throws {
        guard data.last == 0x0A,
              !data.dropLast().contains(0x0A),
              let message = try? JSONDecoder().decode(ACPMessage.self, from: data.dropLast())
        else {
            throw FakeACPTransportError.invalidOutboundFrame
        }

        if shouldSuspendNextSend {
            shouldSuspendNextSend = false
            sendIsSuspended = true
            let waiters = suspendedSendWaiters
            suspendedSendWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                suspendedSendContinuation = continuation
            }
            sendIsSuspended = false
        }

        rawFrames.append(data)
        sentMessages.append(message)

        if sentMessageWaiters.isEmpty {
            unobservedMessages.append(message)
        } else {
            sentMessageWaiters.removeFirst().resume(returning: message)
        }
    }

    func waitForExit() async -> Int32 {
        if let exitStatus {
            return exitStatus
        }

        return await withCheckedContinuation { continuation in
            exitWaiters.append(continuation)
        }
    }

    func terminate() async {
        terminationCount += 1
        suspendedSendContinuation?.resume()
        suspendedSendContinuation = nil
        finish(status: -15)
    }

    func suspendNextSend() {
        shouldSuspendNextSend = true
    }

    func waitUntilSendIsSuspended() async {
        guard !sendIsSuspended else {
            return
        }

        await withCheckedContinuation { continuation in
            suspendedSendWaiters.append(continuation)
        }
    }

    func resumeSuspendedSend() {
        suspendedSendContinuation?.resume()
        suspendedSendContinuation = nil
    }

    func nextSentMessage() async -> ACPMessage {
        if !unobservedMessages.isEmpty {
            return unobservedMessages.removeFirst()
        }

        return await withCheckedContinuation { continuation in
            sentMessageWaiters.append(continuation)
        }
    }

    func feed(_ message: ACPMessage) throws {
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        outputContinuation.yield(data)
    }

    func feedRaw(_ data: Data) {
        outputContinuation.yield(data)
    }

    func finishOutput(status: Int32 = 0) {
        outputContinuation.finish()
        finish(status: status)
    }

    func failOutput() {
        outputContinuation.finish(throwing: FakeACPTransportError.outputFailed)
        finish(status: 1)
    }

    func feedDiagnostic(_ text: String) {
        diagnosticContinuation.yield(Data(text.utf8))
    }

    func allSentMessages() -> [ACPMessage] {
        sentMessages
    }

    func allRawFrames() -> [Data] {
        rawFrames
    }

    func observedTerminationCount() -> Int {
        terminationCount
    }

    func observedOutputCallCount() -> Int {
        outputCallCount
    }

    private func finish(status: Int32) {
        guard exitStatus == nil else {
            return
        }

        exitStatus = status
        outputContinuation.finish()
        diagnosticContinuation.finish()
        let waiters = exitWaiters
        exitWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: status)
        }
    }
}

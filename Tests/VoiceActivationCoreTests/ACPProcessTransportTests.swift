// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore

private actor ACPProcessDrainObservation {
    private var isFinished = false
    private var isStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func started() {
        isStarted = true
        let pending = startWaiters
        startWaiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func finished() {
        isFinished = true
    }

    func waitUntilStarted() async {
        guard !isStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func observedFinish() -> Bool {
        isFinished
    }
}

private final class ACPProcessReadRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private let outputRelease = DispatchSemaphore(value: 0)
    private let diagnosticRelease = DispatchSemaphore(value: 0)
    private var pausedStreams: Set<ACPProcessTransportReadStream> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pause(_ stream: ACPProcessTransportReadStream) {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            pausedStreams.insert(stream)
            guard pausedStreams.count == 2 else {
                return []
            }
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending {
            waiter.resume()
        }
        switch stream {
        case .output:
            outputRelease.wait()
        case .diagnostic:
            diagnosticRelease.wait()
        }
    }

    func waitUntilBothStreamsPause() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                guard pausedStreams.count < 2 else {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func releaseBothStreams() {
        outputRelease.signal()
        diagnosticRelease.signal()
    }
}

private final class ACPProcessRegistrationRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var didPause = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pause() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            didPause = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending {
            waiter.resume()
        }
        release.wait()
    }

    func waitUntilPaused() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                guard !didPause else {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func resume() {
        release.signal()
    }
}

@Suite(.serialized)
struct ACPProcessTransportTests {
    @Test(.timeLimit(.minutes(1)))
    func send_WhenCatIsRunning_ProducesEachFrameIncrementallyAndExactly() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = try ACPProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            currentDirectoryURL: directory)
        let output = await transport.output()
        var iterator = output.makeAsyncIterator()

        try await transport.send(Data("first frame\n".utf8))
        #expect(try await iterator.next() == Data("first frame\n".utf8))

        try await transport.send(Data("second frame\n".utf8))
        #expect(try await iterator.next() == Data("second frame\n".utf8))

        await transport.terminate()
        _ = await transport.waitForExit()
    }

    @Test(.timeLimit(.minutes(1)))
    func launch_WhenFixtureWritesBothStreams_KeepsStandardOutputAndErrorSeparate() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutableFixture(
            in: directory,
            body: "printf 'protocol-output\\n'\nprintf 'private-diagnostic\\n' >&2\n")
        let transport = try ACPProcessTransport(
            executableURL: executable,
            arguments: [],
            currentDirectoryURL: directory)
        let output = await transport.output()
        let diagnostics = await transport.diagnostics()

        async let outputData = collect(output)
        async let diagnosticData = collect(diagnostics)
        #expect(await transport.waitForExit() == 0)

        #expect(try await outputData == Data("protocol-output\n".utf8))
        #expect(await diagnosticData == Data("private-diagnostic\n".utf8))
    }

    @Test(.timeLimit(.minutes(1)))
    func launch_WhenArgumentsDirectoryAndEnvironmentAreSupplied_PreservesThemExactly() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutableFixture(
            in: directory,
            body: "printf '%s\\n%s\\n%s\\n' \"$1\" \"$PWD\" \"$VOICE_ACTIVATION_ACP_TEST\"\n")
        let environmentKey = "VOICE_ACTIVATION_ACP_TEST"
        let environmentValue = "inherited-value"
        setenv(environmentKey, environmentValue, 1)
        defer { unsetenv(environmentKey) }
        let literalArgument = "$(touch must-not-exist); * ; quoted value"
        let transport = try ACPProcessTransport(
            executableURL: executable,
            arguments: [literalArgument],
            currentDirectoryURL: directory)
        let output = await transport.output()

        let outputData = try await collect(output)
        #expect(await transport.waitForExit() == 0)
        let outputLines = String(decoding: outputData, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        #expect(outputLines.count == 4)
        #expect(outputLines[0] == literalArgument)
        let expectedDirectory = try FileManager.default.attributesOfItem(
            atPath: directory.path)
        let observedDirectory = try FileManager.default.attributesOfItem(
            atPath: outputLines[1])
        #expect(
            expectedDirectory[.systemNumber] as? NSNumber
                == observedDirectory[.systemNumber] as? NSNumber)
        #expect(
            expectedDirectory[.systemFileNumber] as? NSNumber
                == observedDirectory[.systemFileNumber] as? NSNumber)
        #expect(outputLines[2] == environmentValue)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("must-not-exist").path))
    }

    @Test(.timeLimit(.minutes(1)))
    func terminate_WhenProcessIsSleeping_ReturnsAndUnblocksEveryExitWaiter() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = try ACPProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["60"],
            currentDirectoryURL: directory)
        async let firstStatus = transport.waitForExit()
        async let secondStatus = transport.waitForExit()

        await transport.terminate()

        let status = await firstStatus
        #expect(status != 0)
        #expect(await secondStatus == status)
        #expect(await transport.waitForExit() == status)
    }

    @Test func launch_WhenExecutableIsNotExecutable_ThrowsWithoutEscapingATransport() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("not-executable")
        try Data("plain data".utf8).write(to: fixture)

        #expect(throws: (any Error).self) {
            _ = try ACPProcessTransport(
                executableURL: fixture,
                arguments: [],
                currentDirectoryURL: directory)
        }
    }

    @Test func send_WhenFrameHasNoTrailingNewline_RejectsIt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = try ACPProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            currentDirectoryURL: directory)

        await #expect(throws: ACPProcessTransportError.invalidFrame) {
            try await transport.send(Data("missing newline".utf8))
        }

        await transport.terminate()
        _ = await transport.waitForExit()
    }

    @Test(.timeLimit(.minutes(1)))
    func send_WhenChildClosesStandardInput_DoesNotTerminateHostProcess() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutableFixture(
            in: directory,
            body: "exec 0<&-\nprintf 'ready\\n'\n/bin/sleep 10\n")
        let transport = try ACPProcessTransport(
            executableURL: executable,
            arguments: [],
            currentDirectoryURL: directory)
        let output = await transport.output()
        var iterator = output.makeAsyncIterator()
        #expect(try await iterator.next() == Data("ready\n".utf8))

        await #expect(throws: ACPProcessTransportError.transportClosed) {
            try await transport.send(Data("frame\n".utf8))
        }

        await transport.terminate()
        _ = await transport.waitForExit()
    }

    @Test(.timeLimit(.minutes(1)))
    func readStreams_WhenDescendantKeepsPipeOpen_CanBeClosedAfterParentExit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutableFixture(
            in: directory,
            body: "(/bin/sleep 10) &\nprintf 'parent-exited\\n'\n")
        let transport = try ACPProcessTransport(
            executableURL: executable,
            arguments: [],
            currentDirectoryURL: directory)
        let drainObservation = ACPProcessDrainObservation()
        let drain = Task {
            await drainObservation.started()
            await transport.waitForDrain()
            await drainObservation.finished()
        }
        await drainObservation.waitUntilStarted()
        #expect(await transport.waitForExit() == 0)
        for _ in 0..<20 {
            await Task.yield()
        }
        let drainFinished = await drainObservation.observedFinish()
        #expect(!drainFinished)

        await transport.closeReadStreams()
        await drain.value
    }

    @Test(.timeLimit(.minutes(1)))
    func terminate_WhenChildExits_CancelsPendingForcedTermination() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = try ACPProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["0.01"],
            currentDirectoryURL: directory)

        await transport.terminate()
        _ = await transport.waitForExit()

        #expect(!transport.hasPendingForcedTerminationForTesting)
    }

    @Test(.timeLimit(.minutes(1)))
    func terminate_WhenDescendantsRetainFullStandardInput_UnblocksWriterPromptly() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeStandardInputRetainingFixture(in: directory)
        let transport = try ACPProcessTransport(
            executableURL: executable,
            arguments: [],
            currentDirectoryURL: directory)
        let output = await transport.output()
        var iterator = output.makeAsyncIterator()
        #expect(try await iterator.next() == Data("ready\n".utf8))
        var frame = Data(repeating: 0x78, count: 4_095)
        frame.append(0x0A)
        let sendStarted = ACPProcessDrainObservation()
        let send = Task {
            await sendStarted.started()
            do {
                while true {
                    try await transport.send(frame)
                }
                return false
            } catch ACPProcessTransportError.transportClosed {
                return true
            } catch {
                return false
            }
        }
        await sendStarted.waitUntilStarted()
        try await ContinuousClock().sleep(for: .milliseconds(100))

        let start = ContinuousClock.now
        await transport.terminate()
        let sendWasClosed = await send.value
        let elapsed = start.duration(to: .now)

        #expect(sendWasClosed)
        #expect(elapsed < .seconds(1))
        await transport.closeReadStreams()
        _ = await transport.waitForExit()
    }

    @Test(.timeLimit(.minutes(1)))
    func closeReadStreams_WhenBothReadersAlreadyHaveBytes_DeliversBytesBeforeEOF() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = ACPProcessReadRaceGate()
        let hooks = ACPProcessTransportTestingHooks(
            beforeYield: { stream in gate.pause(stream) })
        let executable = try makeExecutableFixture(
            in: directory,
            body: "printf 'protocol-output\\n'\nprintf 'private-diagnostic\\n' >&2\n/bin/sleep 10\n")
        let transport = try ACPProcessTransport(
            executableURL: executable,
            arguments: [],
            currentDirectoryURL: directory,
            testingHooks: hooks)
        let output = await transport.output()
        let diagnostics = await transport.diagnostics()
        async let outputData = collect(output)
        async let diagnosticData = collect(diagnostics)
        await gate.waitUntilBothStreamsPause()
        let close = Task { await transport.closeReadStreams() }
        try await ContinuousClock().sleep(for: .milliseconds(100))

        gate.releaseBothStreams()
        await close.value

        #expect(try await outputData == Data("protocol-output\n".utf8))
        #expect(await diagnosticData == Data("private-diagnostic\n".utf8))
        await transport.terminate()
        _ = await transport.waitForExit()
    }

    @Test(.timeLimit(.minutes(1)))
    func waitForDrain_WhenCancelledBeforeRegistration_DoesNotLeaveAWaiter() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = ACPProcessRegistrationRaceGate()
        let hooks = ACPProcessTransportTestingHooks(
            beforeDrainWaiterRegistration: { gate.pause() })
        let transport = try ACPProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            currentDirectoryURL: directory,
            testingHooks: hooks)
        let drain = Task { await transport.waitForDrain() }
        await gate.waitUntilPaused()

        drain.cancel()
        gate.resume()
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(transport.pendingDrainWaiterCountForTesting == 0)
        await transport.closeReadStreams()
        await drain.value
        await transport.terminate()
        _ = await transport.waitForExit()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false)
        return directory
    }

    private func makeExecutableFixture(in directory: URL, body: String) throws -> URL {
        let executable = directory.appendingPathComponent("stream-fixture")
        try Data("#!/bin/sh\n\(body)".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path)
        return executable
    }

    private func makeStandardInputRetainingFixture(in directory: URL) throws -> URL {
        let source = directory.appendingPathComponent("stdin-retainer.c")
        let executable = directory.appendingPathComponent("stdin-retainer")
        let program = """
        #include <signal.h>
        #include <stdlib.h>
        #include <unistd.h>

        int main(void) {
            int ready_pipe[2];
            if (pipe(ready_pipe) != 0) return 1;
            pid_t child = fork();
            if (child < 0) return 2;
            if (child == 0) {
                close(ready_pipe[0]);
                signal(SIGHUP, SIG_IGN);
                signal(SIGTERM, SIG_IGN);
                char ready = '1';
                if (write(ready_pipe[1], &ready, 1) != 1) _exit(3);
                close(ready_pipe[1]);
                sleep(3);
                _exit(0);
            }
            close(ready_pipe[1]);
            char ready = 0;
            if (read(ready_pipe[0], &ready, 1) != 1) return 4;
            close(ready_pipe[0]);
            if (write(STDOUT_FILENO, "ready\\n", 6) != 6) return 5;
            pause();
            return 0;
        }
        """
        try Data(program.utf8).write(to: source)

        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", executable.path]
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            throw CocoaError(.executableLoad)
        }
        return executable
    }

    private func collect(
        _ stream: AsyncThrowingStream<Data, any Error>) async throws -> Data
    {
        var result = Data()
        for try await chunk in stream {
            result.append(chunk)
        }
        return result
    }

    private func collect(_ stream: AsyncStream<Data>) async -> Data {
        var result = Data()
        for await chunk in stream {
            result.append(chunk)
        }
        return result
    }
}

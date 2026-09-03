import Foundation
import Testing
@testable import VoiceActivationCore

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

import Testing
@testable import VoiceActivationCore

struct CommandRunnerTests {
    @Test func run_WhenExecutableSucceeds_ReturnsZeroStatus() async throws {
        let template = try CommandTemplate(
            executablePath: "/usr/bin/printf",
            argumentTemplates: ["%s", "{text}"])

        let result = try await CommandRunner().run(template: template, transcript: "hello")

        #expect(result.terminationStatus == 0)
    }

    @Test func run_WhenExecutableDoesNotExist_ThrowsNotExecutable() async throws {
        let template = try CommandTemplate(
            executablePath: "/does/not/exist",
            argumentTemplates: ["{text}"])

        await #expect(throws: CommandRunnerError.executableIsNotRunnable("/does/not/exist")) {
            try await CommandRunner().run(template: template, transcript: "hello")
        }
    }

    @Test func run_WhenProcessExitsNonzero_ThrowsExitFailure() async throws {
        let template = try CommandTemplate(
            executablePath: "/usr/bin/false",
            argumentTemplates: ["{text}"])

        await #expect(throws: CommandRunnerError.nonzeroExit(1)) {
            try await CommandRunner().run(template: template, transcript: "ignored")
        }
    }
}

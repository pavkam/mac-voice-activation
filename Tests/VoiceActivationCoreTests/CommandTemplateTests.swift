import Foundation
import Testing
@testable import VoiceActivationCore

struct CommandTemplateTests {
    @Test func init_WhenExecutableIsRelative_ThrowsValidationError() {
        #expect(throws: CommandTemplate.ValidationError.executableMustBeAbsolute) {
            try CommandTemplate(executablePath: "open", argumentTemplates: ["{text}"])
        }
    }

    @Test func expandedArguments_WhenUsingText_KeepsTranscriptInOneArgument() throws {
        let template = try CommandTemplate(
            executablePath: "/usr/bin/open",
            argumentTemplates: ["--message={text}"])

        #expect(template.expandedArguments(for: "hello; rm -rf / | nope") == [
            "--message=hello; rm -rf / | nope",
        ])
    }

    @Test func expandedArguments_WhenUsingURLText_UsesQueryValueEncoding() throws {
        let template = try CommandTemplate(
            executablePath: "/usr/bin/open",
            argumentTemplates: ["voice://run?text={urlText}"])

        #expect(template.expandedArguments(for: "café & tea?") == [
            "voice://run?text=caf%C3%A9%20%26%20tea%3F",
        ])
    }

    @Test func init_WhenTemplateHasNoTranscriptPlaceholder_ThrowsValidationError() {
        #expect(throws: CommandTemplate.ValidationError.missingTranscriptPlaceholder) {
            try CommandTemplate(executablePath: "/usr/bin/open", argumentTemplates: ["https://example.com"])
        }
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import YapOpsCore

/// A command and a system action are over in a moment, so the feedback surface
/// has only these events to describe what happened. The order matters as much
/// as the contents: a command must announce that it started before anything can
/// show it running, and must not report an outcome until the process exits.
@MainActor
struct YapOpsCoordinatorActionFeedbackTests {
    typealias Fixture = YapOpsCoordinatorTests.Fixture

    private func systemActionProfile() throws -> WakeProfile {
        try WakeProfile(
            wakePhrase: "mac",
            action: .systemAction(try SystemActionSet(bindings: [
                try SystemActionBinding(action: .lockScreen, phrases: ["lock"]),
            ])),
            accent: .green)
    }

    @Test func command_WhenItSucceeds_ReportsStartedThenSucceeded() async throws {
        let fixture = try Fixture(timing: .fast)
        let log = ActionFeedbackLog()
        fixture.coordinator.onActionFeedback = { log.append($0) }
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("computer hello", isFinal: true)

        await YapOpsCoordinatorTests().waitUntil { log.events().count == 2 }
        #expect(log.events() == [.commandStarted(title: "computer"), .commandSucceeded])
    }

    @Test func command_WhenItExitsNonzero_ReportsTheFailureReason() async throws {
        let runner = FailingCommandRunner(
            error: CommandRunnerError.nonzeroExit(2))
        let template = try CommandTemplate(
            executablePath: "/usr/bin/printf",
            argumentTemplates: ["{text}"])
        let coordinator = YapOpsCoordinator(
            speechSession: FakeSpeechSession(),
            commandRunner: runner,
            configuration: {
                ActivationConfiguration(
                    wakePhrase: "computer",
                    localeID: "en-US",
                    commandTemplate: template)
            },
            timing: .fast)
        let log = ActionFeedbackLog()
        coordinator.onActionFeedback = { log.append($0) }
        let speech = try #require(coordinator.speechSession as? FakeSpeechSession)
        coordinator.setPassiveEnabled(true)

        speech.emit("computer hello", isFinal: true)

        await YapOpsCoordinatorTests().waitUntil { log.events().count == 2 }
        #expect(log.events().first == .commandStarted(title: "computer"))
        guard case .commandFailed(let reason) = log.events().last else {
            Issue.record("expected a command failure, got \(String(describing: log.events().last))")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test func systemAction_WhenItRuns_ReportsTheActionThatRan() async throws {
        let fixture = try Fixture(
            timing: .unreachableCapture,
            profiles: [try systemActionProfile()])
        let log = ActionFeedbackLog()
        fixture.coordinator.onActionFeedback = { log.append($0) }
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("mac lock", isFinal: false)

        await fixture.systemActions.waitForActions()
        await YapOpsCoordinatorTests().waitUntil { !log.events().isEmpty }
        #expect(log.events() == [.systemActionSucceeded(.lockScreen)])
    }

    @Test func systemAction_WhenItCannotRun_ReportsTheActionAndAReason() async throws {
        let fixture = try Fixture(
            timing: .unreachableCapture,
            profiles: [try systemActionProfile()],
            systemActions: RecordingSystemActionPerformer(
                failure: SystemActionError.unsupported(.lockScreen)))
        let log = ActionFeedbackLog()
        fixture.coordinator.onActionFeedback = { log.append($0) }
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("mac lock", isFinal: false)

        await YapOpsCoordinatorTests().waitUntil { !log.events().isEmpty }
        guard case .systemActionFailed(let action, let reason) = log.events().first else {
            Issue.record("expected a system-action failure, got \(log.events())")
            return
        }
        #expect(action == .lockScreen)
        #expect(!reason.isEmpty)
    }
}

/// Collects every feedback event the coordinator publishes.
@MainActor
final class ActionFeedbackLog {
    private var recorded: [ActionFeedbackEvent] = []

    func append(_ event: ActionFeedbackEvent) {
        recorded.append(event)
    }

    func events() -> [ActionFeedbackEvent] {
        recorded
    }
}

/// Reports every command as failing, so the failure path can be exercised
/// without launching a process that really exits nonzero.
actor FailingCommandRunner: CommandRunning {
    private let error: any Error

    init(error: any Error) {
        self.error = error
    }

    func run(template: CommandTemplate, transcript: String) async throws -> CommandResult {
        throw error
    }
}

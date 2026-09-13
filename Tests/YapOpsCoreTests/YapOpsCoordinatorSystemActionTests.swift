// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import YapOpsCore

@MainActor
struct YapOpsCoordinatorSystemActionTests {
    typealias Fixture = YapOpsCoordinatorTests.Fixture

    private func makeProfile() throws -> WakeProfile {
        try WakeProfile(
            wakePhrase: "mac",
            action: .systemAction(try SystemActionSet(bindings: [
                try SystemActionBinding(action: .playPause, phrases: ["play"]),
                try SystemActionBinding(action: .lockScreen, phrases: ["lock"]),
            ])),
            accent: .green)
    }

    @Test func execution_WhenTermIsBound_PerformsThatAction() async throws {
        let fixture = try Fixture(timing: .fast, profiles: [try makeProfile()])
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("mac lock", isFinal: true)

        await YapOpsCoordinatorTests().waitUntil {
            await fixture.systemActions.recordedActions() == [.lockScreen]
        }
    }

    @Test func execution_WhenAnotherTermIsBound_PerformsTheOtherAction() async throws {
        let fixture = try Fixture(timing: .fast, profiles: [try makeProfile()])
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("mac play", isFinal: true)

        await YapOpsCoordinatorTests().waitUntil {
            await fixture.systemActions.recordedActions() == [.playPause]
        }
    }

    // A failure is transient: the cooldown returns the coordinator to listening
    // moments later. Record every transition instead of polling for the state,
    // which under suite-wide main-actor load is missed between polls.
    @Test func execution_WhenTermIsNotBound_FailsWithTheSpokenTerm() async throws {
        let fixture = try Fixture(timing: .fast, profiles: [try makeProfile()])
        let states = StateLog()
        fixture.coordinator.onStateChange = { state in states.append(state) }
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("mac teleport", isFinal: true)

        await YapOpsCoordinatorTests().waitUntil {
            states.failureMessages().contains { $0.contains("teleport") }
        }
        #expect(await fixture.systemActions.recordedActions().isEmpty)
    }

    @Test func execution_WhenTheActionFails_SurfacesItsMessage() async throws {
        let fixture = try Fixture(
            timing: .fast,
            profiles: [try makeProfile()],
            systemActions: RecordingSystemActionPerformer(
                failure: SystemActionError.accessibilityNotGranted(.lockScreen)))
        let states = StateLog()
        fixture.coordinator.onStateChange = { state in states.append(state) }
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("mac lock", isFinal: true)

        await YapOpsCoordinatorTests().waitUntil {
            states.failureMessages().contains { $0.contains("Accessibility") }
        }
    }

    @Test func execution_WhenActionCompletes_ReturnsToListening() async throws {
        let fixture = try Fixture(timing: .fast, profiles: [try makeProfile()])
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("mac play", isFinal: true)

        await YapOpsCoordinatorTests().waitUntil {
            fixture.coordinator.state == .listening
        }
        #expect(await fixture.systemActions.recordedActions() == [.playPause])
    }

    @Test func execution_NeverStartsAnAgentRun() async throws {
        let fixture = try Fixture(timing: .fast, profiles: [try makeProfile()])
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("mac play", isFinal: true)

        await YapOpsCoordinatorTests().waitUntil {
            await fixture.systemActions.recordedActions() == [.playPause]
        }
        #expect(fixture.coordinator.isAgentConversationActive == false)
    }

    @Test func capture_WhenTermCannotGrow_RunsBeforeTheUtteranceEnds() async throws {
        // .standard timing has a capture window measured in seconds; a quick
        // action must not wait for it.
        let fixture = try Fixture(timing: .standard, profiles: [try makeProfile()])
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("mac lock", isFinal: false)

        await YapOpsCoordinatorTests().waitUntil(timeout: .milliseconds(500)) {
            await fixture.systemActions.recordedActions() == [.lockScreen]
        }
    }

    @Test func capture_WhenALongerTermIsReachable_WaitsForTheUtterance() async throws {
        let profile = try WakeProfile(
            wakePhrase: "mac",
            action: .systemAction(try SystemActionSet(bindings: [
                try SystemActionBinding(action: .nextTrack, phrases: ["next", "next track"]),
            ])),
            accent: .green)
        let fixture = try Fixture(timing: .standard, profiles: [profile])
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("mac next", isFinal: false)
        try await Task.sleep(for: .milliseconds(120))

        // Still holding, because "next track" is reachable.
        #expect(await fixture.systemActions.recordedActions().isEmpty)

        fixture.speech.emit("mac next track", isFinal: false)

        await YapOpsCoordinatorTests().waitUntil(timeout: .milliseconds(500)) {
            await fixture.systemActions.recordedActions() == [.nextTrack]
        }
    }

    @Test func capture_ForACommandProfile_StillWaitsForTheUtterance() async throws {
        // Early dispatch belongs to system actions only; dictation must keep
        // its full capture window.
        let fixture = try Fixture(timing: .standard)
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("computer lock", isFinal: false)
        try await Task.sleep(for: .milliseconds(120))

        #expect(await fixture.runner.recordedTranscripts().isEmpty)
    }
}

/// Collects every activation state the coordinator publishes.
@MainActor
final class StateLog {
    private var states: [ActivationState] = []

    func append(_ state: ActivationState) {
        states.append(state)
    }

    func failureMessages() -> [String] {
        states.compactMap {
            guard case let .failed(message) = $0 else { return nil }
            return message
        }
    }
}

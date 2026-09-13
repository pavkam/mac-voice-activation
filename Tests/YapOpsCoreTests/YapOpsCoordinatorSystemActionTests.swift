// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import YapOpsCore

// The time limit is a failure detector for a stuck handshake, never the
// assertion: every wait below resumes on an explicit signal, so a loaded
// machine makes these tests slower rather than red.
@MainActor
@Suite(.timeLimit(.minutes(1)))
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

        await fixture.systemActions.waitForActions()
        #expect(await fixture.systemActions.recordedActions() == [.lockScreen])
    }

    @Test func execution_WhenAnotherTermIsBound_PerformsTheOtherAction() async throws {
        let fixture = try Fixture(timing: .fast, profiles: [try makeProfile()])
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("mac play", isFinal: true)

        await fixture.systemActions.waitForActions()
        #expect(await fixture.systemActions.recordedActions() == [.playPause])
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

        // An unmatched term never reaches the performer, so the failure state is
        // published synchronously by the speech handler itself.
        #expect(states.failureMessages().contains { $0.contains("teleport") })
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

        await fixture.systemActions.waitForActions()
        #expect(await fixture.systemActions.recordedActions() == [.playPause])
        await YapOpsCoordinatorTests().waitUntil {
            fixture.coordinator.state == .listening
        }
    }

    @Test func execution_NeverStartsAnAgentRun() async throws {
        let fixture = try Fixture(timing: .fast, profiles: [try makeProfile()])
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("mac play", isFinal: true)

        await fixture.systemActions.waitForActions()
        #expect(fixture.coordinator.isAgentConversationActive == false)
    }

    @Test func capture_WhenTermCannotGrow_RunsBeforeTheUtteranceEnds() async throws {
        // Under `.unreachableCapture` no capture timer can ever fire, so the run
        // can only come from the early dispatch. The speech handler is
        // synchronous, so execution is already under way when `emit` returns —
        // that ordering, not a wall-clock budget, is the assertion.
        let fixture = try Fixture(timing: .unreachableCapture, profiles: [try makeProfile()])
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("mac lock", isFinal: false)

        #expect(fixture.coordinator.state == .executing)
        await fixture.systemActions.waitForActions()
        #expect(await fixture.systemActions.recordedActions() == [.lockScreen])
    }

    @Test func capture_WhenALongerTermIsReachable_WaitsForTheUtterance() async throws {
        let profile = try WakeProfile(
            wakePhrase: "mac",
            action: .systemAction(try SystemActionSet(bindings: [
                try SystemActionBinding(action: .nextTrack, phrases: ["next", "next track"]),
            ])),
            accent: .green)
        let fixture = try Fixture(timing: .unreachableCapture, profiles: [profile])
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("mac next", isFinal: false)

        // Still holding, because "next track" is reachable. The hold is observed
        // the instant the handler returns rather than waited out, and no timer
        // can dispatch "next" later under this timing.
        #expect(fixture.coordinator.state == .capturing)
        #expect(fixture.coordinator.executingAction == nil)
        #expect(await fixture.systemActions.recordedActions().isEmpty)

        fixture.speech.emit("mac next track", isFinal: false)

        #expect(fixture.coordinator.state == .executing)
        await fixture.systemActions.waitForActions()
        #expect(await fixture.systemActions.recordedActions() == [.nextTrack])
    }

    @Test func capture_ForACommandProfile_StillWaitsForTheUtterance() async throws {
        // Early dispatch belongs to system actions only; dictation must keep
        // its full capture window, which `.unreachableCapture` never reopens.
        let fixture = try Fixture(timing: .unreachableCapture)
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("computer lock", isFinal: false)

        #expect(fixture.coordinator.state == .capturing)
        #expect(fixture.coordinator.executingAction == nil)
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

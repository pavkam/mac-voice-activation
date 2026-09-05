// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationCore


extension VoiceActivationCoordinatorTests {
    @MainActor
    struct Fixture {
        let speech = FakeSpeechSession()
        let runner = RecordingCommandRunner()
        let agentRunner: ControlledAgentRunner
        let coordinator: VoiceActivationCoordinator

        init(
            timing: ActivationTiming = .standard,
            profiles: [WakeProfile]? = nil,
            agentRunner: ControlledAgentRunner = ControlledAgentRunner()) throws
        {
            self.agentRunner = agentRunner
            let template = try CommandTemplate(
                executablePath: "/usr/bin/printf",
                argumentTemplates: ["{text}"])
            coordinator = VoiceActivationCoordinator(
                speechSession: speech,
                commandRunner: runner,
                agentRunner: agentRunner,
                configuration: {
                    if let profiles {
                        return ActivationConfiguration(profiles: profiles, localeID: "en-US")
                    }
                    return ActivationConfiguration(
                        wakePhrase: "computer",
                        localeID: "en-US",
                        commandTemplate: template)
                },
                timing: timing)
        }
    }

    @MainActor func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () async -> Bool) async
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condition was not satisfied before timeout")
    }
}

extension ActivationTiming {
    static let fast = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(200),
        captureInactivity: .milliseconds(20),
        captureMaximum: .milliseconds(40),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let startFailure = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(20),
        captureInactivity: .milliseconds(20),
        captureMaximum: .milliseconds(200),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let initialSilence = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(20),
        captureInactivity: .milliseconds(200),
        captureMaximum: .milliseconds(200),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let initialSilenceCancellation = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(50),
        captureInactivity: .seconds(5),
        captureMaximum: .seconds(10),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let repeatingEmptyFinals = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(500),
        captureInactivity: .milliseconds(500),
        captureMaximum: .milliseconds(200),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let wakeHandoff = ActivationTiming(
        wakeHandoffDelay: .milliseconds(20),
        captureInitialSilence: .milliseconds(200),
        captureInactivity: .milliseconds(20),
        captureMaximum: .milliseconds(500),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let pendingPassiveRestart = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(200),
        captureInactivity: .milliseconds(20),
        captureMaximum: .milliseconds(500),
        passiveRestart: .milliseconds(20),
        executionCooldown: .milliseconds(10))
}

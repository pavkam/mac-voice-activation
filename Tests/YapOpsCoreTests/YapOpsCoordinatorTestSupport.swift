// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import YapOpsCore


extension YapOpsCoordinatorTests {
    @MainActor
    struct Fixture {
        let speech = FakeSpeechSession()
        let runner = RecordingCommandRunner()
        let agentRunner: ControlledAgentRunner
        let systemActions: RecordingSystemActionPerformer
        let coordinator: YapOpsCoordinator

        init(
            timing: ActivationTiming = .standard,
            profiles: [WakeProfile]? = nil,
            agentRunner: ControlledAgentRunner = ControlledAgentRunner(),
            systemActions: RecordingSystemActionPerformer = RecordingSystemActionPerformer(),
            contextCapturer: any MacContextCapturing = EmptyMacContextCapturer(),
            terminalPhrases: @escaping () -> [String] = { AppPreferences.defaultTerminalPhrases },
            diagnostics: any YapOpsDiagnosticRecording = YapOpsDiagnostics.shared
        ) throws
        {
            self.agentRunner = agentRunner
            self.systemActions = systemActions
            let template = try CommandTemplate(
                executablePath: "/usr/bin/printf",
                argumentTemplates: ["{text}"])
            coordinator = YapOpsCoordinator(
                speechSession: speech,
                commandRunner: runner,
                agentRunner: agentRunner,
                systemActionPerformer: systemActions,
                contextCapturer: contextCapturer,
                configuration: {
                    if let profiles {
                        return ActivationConfiguration(profiles: profiles, localeID: "en-US")
                    }
                    return ActivationConfiguration(
                        wakePhrase: "computer",
                        localeID: "en-US",
                        commandTemplate: template)
                },
                terminalPhrases: terminalPhrases,
                timing: timing,
                diagnostics: diagnostics)
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


/// Records performed actions and can be told to fail the next one.
actor RecordingSystemActionPerformer: SystemActionPerforming {
    private var performed: [SystemAction] = []
    private var failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    func perform(_ action: SystemAction) async throws {
        if let failure {
            throw failure
        }
        performed.append(action)
    }

    func recordedActions() -> [SystemAction] {
        performed
    }
}

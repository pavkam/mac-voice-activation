import Foundation

struct ActivationTiming: Sendable {
    static let standard = ActivationTiming(
        wakeHandoffDelay: .milliseconds(350),
        captureInitialSilence: .seconds(5),
        captureInactivity: .seconds(1.5),
        captureMaximum: .seconds(30),
        passiveRestart: .seconds(1),
        executionCooldown: .milliseconds(250))

    let wakeHandoffDelay: Duration
    let captureInitialSilence: Duration
    let captureInactivity: Duration
    let captureMaximum: Duration
    let passiveRestart: Duration
    let executionCooldown: Duration
}

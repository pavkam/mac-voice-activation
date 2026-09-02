import Foundation

struct ActivationTiming: Sendable {
    static let standard = ActivationTiming(
        captureInitialSilence: .seconds(5),
        captureInactivity: .seconds(1.5),
        captureMaximum: .seconds(30),
        passiveRestart: .seconds(1),
        executionCooldown: .milliseconds(250))

    let captureInitialSilence: Duration
    let captureInactivity: Duration
    let captureMaximum: Duration
    let passiveRestart: Duration
    let executionCooldown: Duration
}

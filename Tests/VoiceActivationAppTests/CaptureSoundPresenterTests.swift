import Testing
import VoiceActivationCore
@testable import VoiceActivationApp

@MainActor
private final class CaptureSoundSpy: CaptureSoundPlaying {
    private(set) var events: [CaptureSoundEvent] = []

    func play(_ event: CaptureSoundEvent) {
        events.append(event)
    }
}

struct CaptureSoundPresenterTests {
    @MainActor @Test func update_WhenCaptureStartsAndStops_PlaysBothCuesOnce() {
        let player = CaptureSoundSpy()
        let presenter = CaptureSoundPresenter(player: player)

        presenter.update(state: .listening)
        presenter.update(state: .capturing)
        presenter.update(state: .capturing)
        presenter.update(state: .executing)

        #expect(player.events == [.started, .ended])
    }

    @MainActor @Test func update_WhenNeverCapturing_PlaysNoCue() {
        let player = CaptureSoundSpy()
        let presenter = CaptureSoundPresenter(player: player)

        presenter.update(state: .listening)
        presenter.update(state: .failed("unavailable"))
        presenter.update(state: .disabled)

        #expect(player.events.isEmpty)
    }
}

import Testing
import VoiceActivationCore
@testable import VoiceActivationApp

@MainActor
private final class RecordingOverlayDisplaySpy: RecordingOverlayDisplaying {
    private(set) var shownTranscripts: [String] = []
    private(set) var hideCount = 0

    func show(transcript: String) {
        shownTranscripts.append(transcript)
    }

    func hide() {
        hideCount += 1
    }
}

struct RecordingOverlayPresenterTests {
    @MainActor
    @Test
    func update_WhenCapturing_ShowsLiveTranscript() {
        let display = RecordingOverlayDisplaySpy()
        let presenter = RecordingOverlayPresenter(display: display)

        presenter.update(state: .capturing, transcript: "open calendar")

        #expect(display.shownTranscripts == ["open calendar"])
        #expect(display.hideCount == 0)
    }

    @MainActor
    @Test(arguments: [
        ActivationState.disabled,
        .listening,
        .executing,
        .failed("microphone unavailable"),
    ])
    func update_WhenNotCapturing_HidesOverlay(state: ActivationState) {
        let display = RecordingOverlayDisplaySpy()
        let presenter = RecordingOverlayPresenter(display: display)

        presenter.update(state: state, transcript: "ignored")

        #expect(display.shownTranscripts.isEmpty)
        #expect(display.hideCount == 1)
    }
}

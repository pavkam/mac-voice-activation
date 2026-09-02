import VoiceActivationCore

@MainActor
protocol RecordingOverlayDisplaying: AnyObject {
    func show(transcript: String)
    func hide()
}

@MainActor
final class RecordingOverlayPresenter {
    private let display: any RecordingOverlayDisplaying

    init(display: any RecordingOverlayDisplaying) {
        self.display = display
    }

    func update(state: ActivationState, transcript: String) {
        if state == .capturing {
            display.show(transcript: transcript)
        } else {
            display.hide()
        }
    }
}

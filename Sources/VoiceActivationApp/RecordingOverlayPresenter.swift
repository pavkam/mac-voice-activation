import VoiceActivationCore

@MainActor
protocol RecordingOverlayDisplaying: AnyObject {
    var onCancel: (() -> Void)? { get set }

    func show(transcript: String, accent: WakeProfileAccent)
    func hide()
}

@MainActor
final class RecordingOverlayPresenter {
    private let display: any RecordingOverlayDisplaying
    var onCancel: (() -> Void)?

    init(display: any RecordingOverlayDisplaying) {
        self.display = display
        display.onCancel = { [weak self] in
            self?.onCancel?()
        }
    }

    func update(
        state: ActivationState,
        transcript: String,
        accent: WakeProfileAccent = .blue)
    {
        if state == .capturing {
            display.show(transcript: transcript, accent: accent)
        } else {
            display.hide()
        }
    }
}

import Observation
import VoiceActivationCore

@MainActor
@Observable
final class RecordingOverlayModel {
    var transcript = ""
    var isRecording = false
    var accent: WakeProfileAccent = .blue
    @ObservationIgnored var onCancel: (() -> Void)?
}

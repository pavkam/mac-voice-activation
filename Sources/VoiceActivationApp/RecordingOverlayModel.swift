import Observation

@MainActor
@Observable
final class RecordingOverlayModel {
    var transcript = ""
    var isRecording = false
}

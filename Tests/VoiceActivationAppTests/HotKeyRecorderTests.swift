import Testing
@testable import VoiceActivationApp

struct HotKeyRecorderTests {
    @MainActor @Test func recording_WhenStartedAndStopped_PublishesLifecycle() {
        let recorder = HotKeyRecorder()
        var recordingStates: [Bool] = []

        recorder.toggle(
            onCapture: { _ in },
            onRecordingChange: { recordingStates.append($0) })
        recorder.stop()

        #expect(recordingStates == [true, false])
    }
}

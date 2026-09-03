import AppKit
import Carbon.HIToolbox
import Testing
@testable import VoiceActivationApp
import VoiceActivationCore

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

    @MainActor @Test func capture_WhenModifiedKeyIsPressed_PublishesBindingAndStops() throws {
        let recorder = HotKeyRecorder()
        var captured: [PushToTalkHotKey] = []
        var recordingStates: [Bool] = []
        recorder.toggle(
            onCapture: { captured.append($0) },
            onRecordingChange: { recordingStates.append($0) })

        recorder.capture(try keyEvent(
            keyCode: UInt16(kVK_ANSI_K),
            modifiers: [.control, .shift],
            characters: "k"))

        #expect(captured.first?.displayName == "⌃⇧K")
        #expect(recordingStates == [true, false])
        #expect(!recorder.isRecording)
    }

    @MainActor @Test func capture_WhenEscapeIsPressed_CancelsWithoutBinding() throws {
        let recorder = HotKeyRecorder()
        var captureCount = 0
        var recordingStates: [Bool] = []
        recorder.toggle(
            onCapture: { _ in captureCount += 1 },
            onRecordingChange: { recordingStates.append($0) })

        recorder.capture(try keyEvent(
            keyCode: UInt16(kVK_Escape),
            modifiers: [],
            characters: "\u{1b}"))

        #expect(captureCount == 0)
        #expect(recordingStates == [true, false])
        #expect(!recorder.isRecording)
    }

    @MainActor @Test func capture_WhenModifierIsMissing_KeepsRecordingAndShowsGuidance() throws {
        let recorder = HotKeyRecorder()
        recorder.toggle(onCapture: { _ in }, onRecordingChange: { _ in })

        recorder.capture(try keyEvent(
            keyCode: UInt16(kVK_ANSI_K),
            modifiers: [],
            characters: "k"))

        #expect(recorder.isRecording)
        #expect(recorder.errorMessage == "Include Control, Option, Shift, or Command.")
        recorder.stop()
    }

    @MainActor
    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String) throws -> NSEvent
    {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode))
    }
}

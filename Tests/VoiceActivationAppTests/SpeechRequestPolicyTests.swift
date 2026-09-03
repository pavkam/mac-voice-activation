import Speech
import Testing
@testable import VoiceActivationApp

struct SpeechRequestPolicyTests {
    @Test func configure_WhenPassiveAndOnDeviceUnavailable_Throws() {
        let request = SFSpeechAudioBufferRecognitionRequest()

        #expect(throws: SpeechRequestPolicy.PolicyError.onDeviceRecognitionUnavailable) {
            try SpeechRequestPolicy.configure(request, mode: .passiveWake, supportsOnDeviceRecognition: false)
        }
    }

    @Test func configure_WhenPassive_RequiresOnDeviceAndPartialResults() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()

        try SpeechRequestPolicy.configure(
            request,
            mode: .passiveWake,
            supportsOnDeviceRecognition: true,
            contextualStrings: ["computer", "sneek"])

        #expect(request.requiresOnDeviceRecognition)
        #expect(request.shouldReportPartialResults)
        #expect(request.contextualStrings == ["computer", "sneek"])
    }

    @Test func configure_WhenPushToTalk_AllowsRecognizerDefault() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()

        try SpeechRequestPolicy.configure(request, mode: .pushToTalk, supportsOnDeviceRecognition: false)

        #expect(!request.requiresOnDeviceRecognition)
        #expect(request.shouldReportPartialResults)
    }

    @Test func configure_WhenCapturingCommand_AllowsRecognizerDefault() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()

        try SpeechRequestPolicy.configure(
            request,
            mode: .commandCapture,
            supportsOnDeviceRecognition: false)

        #expect(!request.requiresOnDeviceRecognition)
        #expect(request.shouldReportPartialResults)
    }

    @Test func configure_WhenConversationIsActive_AllowsRecognizerDefault() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()

        try SpeechRequestPolicy.configure(
            request,
            mode: .conversation,
            supportsOnDeviceRecognition: false)

        #expect(!request.requiresOnDeviceRecognition)
        #expect(request.shouldReportPartialResults)
    }
}

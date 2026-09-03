import Speech
import VoiceActivationCore

enum SpeechRequestPolicy {
    enum PolicyError: Error, Equatable, LocalizedError {
        case onDeviceRecognitionUnavailable

        var errorDescription: String? {
            "On-device speech recognition is unavailable for this language on this Mac."
        }
    }

    static func configure(
        _ request: SFSpeechAudioBufferRecognitionRequest,
        mode: SpeechSessionMode,
        supportsOnDeviceRecognition: Bool,
        contextualStrings: [String] = []) throws
    {
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        switch mode {
        case .passiveWake:
            guard supportsOnDeviceRecognition else {
                throw PolicyError.onDeviceRecognitionUnavailable
            }
            request.requiresOnDeviceRecognition = true
            request.contextualStrings = contextualStrings
        case .commandCapture, .conversation, .pushToTalk:
            request.requiresOnDeviceRecognition = false
        }
    }
}

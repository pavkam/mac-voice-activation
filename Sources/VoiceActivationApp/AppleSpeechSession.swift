import AVFoundation
import Foundation
import Speech
import VoiceActivationCore

@MainActor
final class AppleSpeechSession: SpeechSessionProtocol {
    enum SessionError: Error, LocalizedError {
        case recognizerUnavailable(String)
        case noAudioInput

        var errorDescription: String? {
            switch self {
            case let .recognizerUnavailable(locale):
                "Speech recognition is unavailable for \(locale)."
            case .noAudioInput:
                "No usable microphone input is available."
            }
        }
    }

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInputTap = false
    private var generation = 0

    func start(
        mode: SpeechSessionMode,
        localeID: String,
        onUpdate: @escaping (SpeechUpdate) -> Void) throws
    {
        stop()
        generation &+= 1
        let activeGeneration = generation
        let locale = Locale(identifier: localeID)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SessionError.recognizerUnavailable(localeID)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        try SpeechRequestPolicy.configure(
            request,
            mode: mode,
            supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw SessionError.noAudioInput
        }

        let bufferSink = SpeechAudioBufferSink(request: request)
        input.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: format,
            block: bufferSink.makeTap())
        hasInputTap = true
        recognitionRequest = request
        audioEngine = engine

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString ?? ""
            let isFinal = result?.isFinal ?? false
            let errorDescription = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                onUpdate(SpeechUpdate(
                    transcript: transcript,
                    isFinal: isFinal,
                    errorDescription: errorDescription))
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        generation &+= 1
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if hasInputTap, let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        hasInputTap = false
        audioEngine?.stop()
        audioEngine = nil
    }
}

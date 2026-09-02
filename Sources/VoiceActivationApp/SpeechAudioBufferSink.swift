@preconcurrency import AVFoundation
@preconcurrency import Speech

final class SpeechAudioBufferSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }

    func makeTap() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in
            append(buffer)
        }
    }
}

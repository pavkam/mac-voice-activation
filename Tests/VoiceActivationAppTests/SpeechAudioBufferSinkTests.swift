// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

@preconcurrency import AVFoundation
import Speech
import Testing
@testable import VoiceActivationApp

private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

struct SpeechAudioBufferSinkTests {
    @Test func append_WhenAudioTapRunsOffMainActor_CompletesWithoutIsolationFailure() async throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        let sink = SpeechAudioBufferSink(request: request)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        let boxedBuffer = UncheckedSendableBox(value: buffer)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                sink.append(boxedBuffer.value)
                continuation.resume()
            }
        }
    }
}

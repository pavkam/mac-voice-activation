// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AVFoundation
import Speech
import Testing

@testable import YapOpsApp
@testable import YapOpsCore

/// Guards a real crash this application shipped: a closure literal written
/// directly inside a `@MainActor` instance method is isolated to that actor by
/// lexical context alone, regardless of what it captures. `AVAudioEngine`
/// invokes a recognition tap from its own real-time thread, never the main
/// actor, so a tap block built that way carries a runtime isolation check that
/// fails on the very first buffer — an immediate `EXC_BREAKPOINT`, not a
/// warning, and not something `#expect` can catch after the fact. The
/// regression signal here is the test process surviving at all: if
/// `AppleSpeechSession.makeTap` regresses to a `@MainActor`-inferred closure,
/// this test crashes the same way the app did, on any thread that is not main.
@Suite struct AppleSpeechSessionTests {
    @Test func tapBlockRunsOffTheMainActorWithoutTrapping() async throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        let bufferSink = SpeechAudioBufferSink(request: request)
        let levelMeter = SpeechAudioLevelMeter(scheduler: MainRunLoopScheduler()) { _ in }
        let tap = AppleSpeechSession.makeTap(bufferSink: bufferSink, levelMeter: levelMeter)
        let buffer = try #require(makeSilentBuffer())

        // Off the main actor, on purpose: this is what AVAudioEngine actually
        // does. A synchronous MainActor call from here is the crash.
        await Task.detached(priority: .userInitiated) {
            for _ in 0..<10 {
                tap(buffer, AVAudioTime())
            }
        }.value
    }

    private func makeSilentBuffer() -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256) else {
            return nil
        }
        buffer.frameLength = 256
        return buffer
    }
}

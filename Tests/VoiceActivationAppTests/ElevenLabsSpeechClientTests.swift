// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import VoiceActivationApp

private actor ElevenLabsRequestRecorder {
    private var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }

    func recordedRequest() -> URLRequest? {
        request
    }
}

struct ElevenLabsSpeechClientTests {
    @Test func audio_WhenRequestSucceeds_UsesLowLatencyStreamingContract() async throws {
        let recorder = ElevenLabsRequestRecorder()
        let expectedAudio = Data([1, 2, 3])
        let client = ElevenLabsSpeechClient(dataLoader: { request in
            await recorder.record(request)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "audio/mpeg"]))
            return (expectedAudio, response)
        })

        let audio = try await client.audio(
            text: "Hello from the agent.",
            apiKey: "test-secret",
            voiceID: "voice-123")

        #expect(audio == expectedAudio)
        let request = try #require(await recorder.recordedRequest())
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString ==
            "https://api.elevenlabs.io/v1/text-to-speech/voice-123/stream?output_format=mp3_44100_128")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "test-secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["text"] as? String == "Hello from the agent.")
        #expect(json["model_id"] as? String == "eleven_flash_v2_5")
    }

    @Test func audio_WhenServerRejectsRequest_ThrowsBoundedStatusError() async throws {
        let client = ElevenLabsSpeechClient(dataLoader: { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: nil))
            return (Data("private response".utf8), response)
        })

        await #expect(throws: ElevenLabsSpeechClientError.httpStatus(401)) {
            try await client.audio(
                text: "Hello.",
                apiKey: "invalid",
                voiceID: "voice-123")
        }
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import VoiceActivationCore

protocol ElevenLabsSpeechSynthesizing: Sendable {
    func audio(text: String, apiKey: String, voiceID: String) async throws -> Data
}

enum ElevenLabsSpeechClientError: Error, Equatable, LocalizedError {
    case invalidVoiceID
    case invalidResponse
    case httpStatus(Int)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .invalidVoiceID:
            "The ElevenLabs voice ID is invalid."
        case .invalidResponse:
            "ElevenLabs returned an invalid response."
        case .httpStatus(let status):
            "ElevenLabs speech failed with HTTP status \(status)."
        case .emptyAudio:
            "ElevenLabs returned no audio."
        }
    }
}

struct ElevenLabsSpeechClient: ElevenLabsSpeechSynthesizing {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct RequestBody: Encodable {
        struct VoiceSettings: Encodable {
            let stability = 0.45
            let similarityBoost = 0.75
            let style = 0.0
            let useSpeakerBoost = true
            let speed = 1.0

            private enum CodingKeys: String, CodingKey {
                case stability
                case similarityBoost = "similarity_boost"
                case style
                case useSpeakerBoost = "use_speaker_boost"
                case speed
            }
        }

        let text: String
        let modelID = "eleven_flash_v2_5"
        let voiceSettings = VoiceSettings()

        private enum CodingKeys: String, CodingKey {
            case text
            case modelID = "model_id"
            case voiceSettings = "voice_settings"
        }
    }

    private let dataLoader: DataLoader
    private let diagnostics: any VoiceActivationDiagnosticRecording

    init(
        session: URLSession = .shared,
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        dataLoader = { request in
            try await session.data(for: request)
        }
        self.diagnostics = diagnostics
    }

    init(
        dataLoader: @escaping DataLoader,
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.dataLoader = dataLoader
        self.diagnostics = diagnostics
    }

    func audio(text: String, apiKey: String, voiceID: String) async throws -> Data {
        let requestID = UUID().uuidString
        let startedAtUptime = DispatchTime.now().uptimeNanoseconds
        let voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voiceID.isEmpty,
            voiceID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else {
            diagnostics.record(
                category: .network,
                event: "elevenlabs.speech_rejected",
                level: .warning,
                fields: [
                    "network_request_id": requestID,
                    "reason": "invalid_voice_id",
                    "character_count": String(text.count),
                ])
            throw ElevenLabsSpeechClientError.invalidVoiceID
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.elevenlabs.io"
        components.path = "/v1/text-to-speech/\(voiceID)/stream"
        components.queryItems = [
            URLQueryItem(name: "output_format", value: "mp3_44100_128")
        ]
        guard let url = components.url else {
            throw ElevenLabsSpeechClientError.invalidVoiceID
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = try JSONEncoder().encode(RequestBody(text: text))

        diagnostics.record(
            category: .network,
            event: "elevenlabs.speech_request_started",
            fields: [
                "network_request_id": requestID,
                "character_count": String(text.count),
                "request_byte_count": String(request.httpBody?.count ?? 0),
            ])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await dataLoader(request)
        } catch {
            diagnostics.record(
                category: .network,
                event: "elevenlabs.speech_request_failed",
                level: error is CancellationError ? .info : .error,
                fields: [
                    "network_request_id": requestID,
                    "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
                    "outcome": error is CancellationError ? "cancelled" : "transport_error",
                    "error_type": String(describing: type(of: error)),
                ])
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            diagnostics.record(
                category: .network,
                event: "elevenlabs.speech_response_invalid",
                level: .error,
                fields: [
                    "network_request_id": requestID,
                    "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
                    "response_byte_count": String(data.count),
                ])
            throw ElevenLabsSpeechClientError.invalidResponse
        }
        diagnostics.record(
            category: .network,
            event: "elevenlabs.speech_response_received",
            level: (200..<300).contains(httpResponse.statusCode) ? .info : .error,
            fields: [
                "network_request_id": requestID,
                "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
                "http_status": String(httpResponse.statusCode),
                "response_byte_count": String(data.count),
            ])
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ElevenLabsSpeechClientError.httpStatus(httpResponse.statusCode)
        }
        guard !data.isEmpty else {
            throw ElevenLabsSpeechClientError.emptyAudio
        }
        return data
    }

    private static func elapsedMilliseconds(since start: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= start else { return 0 }
        return (now - start) / 1_000_000
    }
}

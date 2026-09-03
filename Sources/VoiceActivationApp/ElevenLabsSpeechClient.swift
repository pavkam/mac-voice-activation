import Foundation

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
        case let .httpStatus(status):
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

    init(session: URLSession = .shared) {
        dataLoader = { request in
            try await session.data(for: request)
        }
    }

    init(dataLoader: @escaping DataLoader) {
        self.dataLoader = dataLoader
    }

    func audio(text: String, apiKey: String, voiceID: String) async throws -> Data {
        let voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voiceID.isEmpty,
              voiceID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else {
            throw ElevenLabsSpeechClientError.invalidVoiceID
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.elevenlabs.io"
        components.path = "/v1/text-to-speech/\(voiceID)/stream"
        components.queryItems = [
            URLQueryItem(name: "output_format", value: "mp3_44100_128"),
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

        let (data, response) = try await dataLoader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsSpeechClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ElevenLabsSpeechClientError.httpStatus(httpResponse.statusCode)
        }
        guard !data.isEmpty else {
            throw ElevenLabsSpeechClientError.emptyAudio
        }
        return data
    }
}

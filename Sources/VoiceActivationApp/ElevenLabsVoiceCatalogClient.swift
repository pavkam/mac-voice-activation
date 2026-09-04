// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import VoiceActivationCore

struct ElevenLabsVoice: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let category: String?
    let description: String?
}

protocol ElevenLabsVoiceCatalogLoading: Sendable {
    func voices(apiKey: String) async throws -> [ElevenLabsVoice]
}

enum ElevenLabsVoiceCatalogError: Error, Equatable, LocalizedError {
    case apiKeyRequired
    case invalidResponse
    case httpStatus(Int)
    case invalidPayload
    case paginationLimitReached

    var errorDescription: String? {
        switch self {
        case .apiKeyRequired:
            "Enter an ElevenLabs API key to load voices."
        case .invalidResponse:
            "ElevenLabs returned an invalid voice-catalog response."
        case .httpStatus(let status):
            "ElevenLabs voice loading failed with HTTP status \(status)."
        case .invalidPayload:
            "ElevenLabs returned an unreadable voice catalog."
        case .paginationLimitReached:
            "ElevenLabs returned too many voice-catalog pages."
        }
    }
}

struct ElevenLabsVoiceCatalogClient: ElevenLabsVoiceCatalogLoading {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let maximumPages = 10

    private struct Page: Decodable {
        let voices: [Voice]
        let hasMore: Bool
        let nextPageToken: String?

        private enum CodingKeys: String, CodingKey {
            case voices
            case hasMore = "has_more"
            case nextPageToken = "next_page_token"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            voices = try container.decode([Voice].self, forKey: .voices)
            hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
            nextPageToken = try container.decodeIfPresent(
                String.self,
                forKey: .nextPageToken)
        }
    }

    private struct Voice: Decodable {
        let id: String
        let name: String
        let category: String?
        let description: String?

        private enum CodingKeys: String, CodingKey {
            case id = "voice_id"
            case name
            case category
            case description
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

    func voices(apiKey: String) async throws -> [ElevenLabsVoice] {
        let requestID = UUID().uuidString
        let startedAtUptime = DispatchTime.now().uptimeNanoseconds
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            diagnostics.record(
                category: .network,
                event: "elevenlabs.voice_catalog_rejected",
                level: .warning,
                fields: ["reason": "api_key_missing"])
            throw ElevenLabsVoiceCatalogError.apiKeyRequired
        }
        diagnostics.record(
            category: .network,
            event: "elevenlabs.voice_catalog_started",
            fields: ["network_request_id": requestID])

        var result: [ElevenLabsVoice] = []
        var seenVoiceIDs: Set<String> = []
        var seenPageTokens: Set<String> = []
        var nextPageToken: String?
        var pageCount = 0

        repeat {
            guard pageCount < Self.maximumPages else {
                throw ElevenLabsVoiceCatalogError.paginationLimitReached
            }
            pageCount += 1

            let request = try request(apiKey: apiKey, nextPageToken: nextPageToken)
            let pageStartedAtUptime = DispatchTime.now().uptimeNanoseconds
            diagnostics.record(
                category: .network,
                event: "elevenlabs.voice_catalog_page_started",
                fields: [
                    "network_request_id": requestID,
                    "page": String(pageCount),
                ])
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await dataLoader(request)
            } catch {
                diagnostics.record(
                    category: .network,
                    event: "elevenlabs.voice_catalog_failed",
                    level: error is CancellationError ? .info : .error,
                    fields: [
                        "network_request_id": requestID,
                        "page": String(pageCount),
                        "duration_ms": String(
                            Self.elapsedMilliseconds(
                                since: startedAtUptime)),
                        "error_type": String(describing: type(of: error)),
                    ])
                throw error
            }
            guard let response = response as? HTTPURLResponse else {
                throw ElevenLabsVoiceCatalogError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw ElevenLabsVoiceCatalogError.httpStatus(response.statusCode)
            }
            diagnostics.record(
                category: .network,
                event: "elevenlabs.voice_catalog_page_received",
                fields: [
                    "network_request_id": requestID,
                    "page": String(pageCount),
                    "duration_ms": String(
                        Self.elapsedMilliseconds(
                            since: pageStartedAtUptime)),
                    "http_status": String(response.statusCode),
                    "response_byte_count": String(data.count),
                ])

            let page: Page
            do {
                page = try JSONDecoder().decode(Page.self, from: data)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ElevenLabsVoiceCatalogError.invalidPayload
            }

            for voice in page.voices {
                let id = voice.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, seenVoiceIDs.insert(id).inserted else { continue }
                let name = voice.name.trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(
                    ElevenLabsVoice(
                        id: id,
                        name: name.isEmpty ? "Unnamed voice" : name,
                        category: voice.category?.nilIfBlank,
                        description: voice.description?.nilIfBlank))
            }

            guard page.hasMore else {
                nextPageToken = nil
                continue
            }
            guard let token = page.nextPageToken?.nilIfBlank,
                seenPageTokens.insert(token).inserted
            else {
                throw ElevenLabsVoiceCatalogError.invalidResponse
            }
            nextPageToken = token
        } while nextPageToken != nil

        let sorted = result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        diagnostics.record(
            category: .network,
            event: "elevenlabs.voice_catalog_finished",
            fields: [
                "network_request_id": requestID,
                "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
                "page_count": String(pageCount),
                "voice_count": String(sorted.count),
            ])
        return sorted
    }

    private func request(apiKey: String, nextPageToken: String?) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.elevenlabs.io"
        components.path = "/v2/voices"
        components.queryItems = [
            URLQueryItem(name: "page_size", value: "100"),
            URLQueryItem(name: "sort", value: "name"),
            URLQueryItem(name: "sort_direction", value: "asc"),
            URLQueryItem(name: "include_total_count", value: "false"),
        ]
        if let nextPageToken {
            components.queryItems?.append(
                URLQueryItem(
                    name: "next_page_token",
                    value: nextPageToken))
        }
        guard let url = components.url else {
            throw ElevenLabsVoiceCatalogError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    private static func elapsedMilliseconds(since start: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= start else { return 0 }
        return (now - start) / 1_000_000
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

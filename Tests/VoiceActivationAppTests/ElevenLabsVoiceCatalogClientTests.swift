import Foundation
import Testing
@testable import VoiceActivationApp

private actor ElevenLabsVoiceCatalogRequestRecorder {
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

struct ElevenLabsVoiceCatalogClientTests {
    @Test func voices_WhenCatalogIsPaginated_LoadsEveryPageAndSortsByName() async throws {
        let recorder = ElevenLabsVoiceCatalogRequestRecorder()
        let client = ElevenLabsVoiceCatalogClient(dataLoader: { request in
            await recorder.record(request)
            let url = try #require(request.url)
            let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "next_page_token" })?.value
            let payload: String
            if token == nil {
                payload = """
                {"voices":[{"voice_id":"zeta-id","name":"Zeta","category":"premade","description":"Warm"}],"has_more":true,"next_page_token":"page-2"}
                """
            } else {
                payload = """
                {"voices":[{"voice_id":"alpha-id","name":"Alpha","category":"cloned","description":null}],"has_more":false,"next_page_token":null}
                """
            }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]))
            return (Data(payload.utf8), response)
        })

        let voices = try await client.voices(apiKey: "test-secret")

        #expect(voices == [
            ElevenLabsVoice(
                id: "alpha-id",
                name: "Alpha",
                category: "cloned",
                description: nil),
            ElevenLabsVoice(
                id: "zeta-id",
                name: "Zeta",
                category: "premade",
                description: "Warm"),
        ])
        let requests = await recorder.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy {
            $0.httpMethod == "GET"
                && $0.value(forHTTPHeaderField: "xi-api-key") == "test-secret"
        })
        let firstURL = try #require(requests.first?.url?.absoluteString)
        #expect(firstURL.contains("https://api.elevenlabs.io/v2/voices?"))
        #expect(firstURL.contains("page_size=100"))
        #expect(firstURL.contains("sort=name"))
        #expect(firstURL.contains("sort_direction=asc"))
        #expect(requests.last?.url?.absoluteString.contains("next_page_token=page-2") == true)
    }

    @Test func voices_WhenServerRejectsRequest_ThrowsStatusWithoutLeakingBody() async throws {
        let client = ElevenLabsVoiceCatalogClient(dataLoader: { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: nil))
            return (Data("private response".utf8), response)
        })

        await #expect(throws: ElevenLabsVoiceCatalogError.httpStatus(401)) {
            try await client.voices(apiKey: "invalid")
        }
    }

    @Test func voices_WhenVoiceHasNoIdentifier_DropsMalformedEntry() async throws {
        let client = ElevenLabsVoiceCatalogClient(dataLoader: { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil))
            let payload = """
            {"voices":[{"voice_id":"","name":"Broken"},{"voice_id":"valid","name":"Valid"}],"has_more":false}
            """
            return (Data(payload.utf8), response)
        })

        #expect(try await client.voices(apiKey: "key") == [
            ElevenLabsVoice(
                id: "valid",
                name: "Valid",
                category: nil,
                description: nil),
        ])
    }
}

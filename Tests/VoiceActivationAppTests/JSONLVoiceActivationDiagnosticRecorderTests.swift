// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import VoiceActivationApp
@testable import VoiceActivationCore

struct JSONLVoiceActivationDiagnosticRecorderTests {
    @Test func record_WhenFlushed_WritesStructuredMetadataAndRedactsSensitiveFields()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try JSONLVoiceActivationDiagnosticRecorder(
            directoryURL: directory,
            sessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            maximumFileSize: 1_000_000,
            retainedFileCount: 2)

        recorder.record(
            category: .audio,
            event: "speech.synthesis_finished",
            level: .info,
            fields: [
                "request_id": "17",
                "duration_ms": "842",
                "prompt": "private words",
                "api_key": "private credential",
            ])
        recorder.flush()

        let data = try Data(contentsOf: recorder.currentLogURL)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
        #expect(lines.count == 1)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(object["schema_version"] as? Int == 1)
        #expect(object["session_id"] as? String == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(object["sequence"] as? Int == 1)
        #expect(object["category"] as? String == "audio")
        #expect(object["event"] as? String == "speech.synthesis_finished")
        #expect(object["level"] as? String == "info")
        let fields = try #require(object["fields"] as? [String: String])
        #expect(fields["request_id"] == "17")
        #expect(fields["duration_ms"] == "842")
        #expect(fields["prompt"] == "<redacted>")
        #expect(fields["api_key"] == "<redacted>")
    }

    @Test func record_WhenCurrentFileExceedsItsBound_RotatesAndRetainsNewestEvents()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try JSONLVoiceActivationDiagnosticRecorder(
            directoryURL: directory,
            maximumFileSize: 700,
            retainedFileCount: 2)

        for index in 0..<12 {
            recorder.record(
                category: .app,
                event: "rotation_probe",
                fields: ["index": "\(index)", "padding": String(repeating: "x", count: 80)])
        }
        recorder.flush()

        #expect(FileManager.default.fileExists(atPath: recorder.currentLogURL.path))
        #expect(FileManager.default.fileExists(atPath: recorder.rotatedLogURLs[0].path))
        let newest = try String(contentsOf: recorder.currentLogURL, encoding: .utf8)
        #expect(newest.contains("\"index\":\"11\""))
        #expect(recorder.rotatedLogURLs.count == 2)
    }
}

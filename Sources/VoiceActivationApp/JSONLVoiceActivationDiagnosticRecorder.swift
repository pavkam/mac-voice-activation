// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import VoiceActivationCore

final class JSONLVoiceActivationDiagnosticRecorder: VoiceActivationDiagnosticRecording,
    @unchecked Sendable
{
    static let defaultDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VoiceActivation", isDirectory: true)

    let currentLogURL: URL
    let rotatedLogURLs: [URL]

    private struct Record: Encodable {
        let schemaVersion: Int
        let timestamp: String
        let uptimeMilliseconds: UInt64
        let sessionElapsedMilliseconds: UInt64
        let sessionID: String
        let sequence: UInt64
        let processID: Int32
        let mainThread: Bool
        let category: String
        let event: String
        let level: String
        let fields: [String: String]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case timestamp
            case uptimeMilliseconds = "uptime_ms"
            case sessionElapsedMilliseconds = "session_elapsed_ms"
            case sessionID = "session_id"
            case sequence
            case processID = "process_id"
            case mainThread = "main_thread"
            case category
            case event
            case level
            case fields
        }
    }

    private static let sensitiveFieldFragments = [
        "api_key", "authorization", "content", "credential", "prompt", "secret", "text",
        "token", "transcript",
    ]

    private static let maximumFieldValueLength = 512

    private let queue = DispatchQueue(
        label: "dev.alex.voice-activation.diagnostics",
        qos: .userInitiated)
    private let sessionID: String
    private let sessionStartedAtUptime: UInt64
    private let maximumFileSize: UInt64
    private let encoder: JSONEncoder
    private let timestampFormatter: ISO8601DateFormatter
    private var handle: FileHandle
    private var sequence: UInt64 = 0

    init(
        directoryURL: URL = JSONLVoiceActivationDiagnosticRecorder.defaultDirectoryURL,
        sessionID: UUID = UUID(),
        maximumFileSize: UInt64 = 5 * 1_024 * 1_024,
        retainedFileCount: Int = 3
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true)
        currentLogURL = directoryURL.appendingPathComponent("voice-activation.jsonl")
        rotatedLogURLs = (1...max(1, retainedFileCount)).map {
            directoryURL.appendingPathComponent("voice-activation.jsonl.\($0)")
        }
        if !fileManager.fileExists(atPath: currentLogURL.path) {
            _ = fileManager.createFile(atPath: currentLogURL.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: currentLogURL)
        try handle.seekToEnd()
        self.sessionID = sessionID.uuidString
        sessionStartedAtUptime = DispatchTime.now().uptimeNanoseconds
        self.maximumFileSize = max(1, maximumFileSize)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestampFormatter = timestampFormatter
    }

    func record(
        category: VoiceActivationDiagnosticCategory,
        event: String,
        level: VoiceActivationDiagnosticLevel,
        fields: [String: String]
    ) {
        let timestamp = Date()
        let uptime = DispatchTime.now().uptimeNanoseconds
        let wasMainThread = Thread.isMainThread
        queue.async { [self] in
            sequence &+= 1
            let record = Record(
                schemaVersion: 1,
                timestamp: timestampFormatter.string(from: timestamp),
                uptimeMilliseconds: uptime / 1_000_000,
                sessionElapsedMilliseconds: (uptime - sessionStartedAtUptime) / 1_000_000,
                sessionID: sessionID,
                sequence: sequence,
                processID: ProcessInfo.processInfo.processIdentifier,
                mainThread: wasMainThread,
                category: category.rawValue,
                event: String(event.prefix(160)),
                level: level.rawValue,
                fields: Self.sanitized(fields))
            guard var data = try? encoder.encode(record) else { return }
            data.append(0x0A)
            rotateIfNeeded(for: UInt64(data.count))
            try? handle.write(contentsOf: data)
        }
    }

    func flush() {
        queue.sync {
            try? handle.synchronize()
        }
    }

    private func rotateIfNeeded(for incomingByteCount: UInt64) {
        let currentSize = handle.offsetInFile
        guard currentSize > 0, currentSize + incomingByteCount > maximumFileSize else { return }

        try? handle.close()
        let fileManager = FileManager.default
        for index in stride(from: rotatedLogURLs.count - 1, through: 1, by: -1) {
            let destination = rotatedLogURLs[index]
            let source = rotatedLogURLs[index - 1]
            try? fileManager.removeItem(at: destination)
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: source, to: destination)
            }
        }
        if let firstRotation = rotatedLogURLs.first {
            try? fileManager.removeItem(at: firstRotation)
            try? fileManager.moveItem(at: currentLogURL, to: firstRotation)
        }
        _ = fileManager.createFile(atPath: currentLogURL.path, contents: nil)
        if let replacement = try? FileHandle(forWritingTo: currentLogURL) {
            handle = replacement
        }
    }

    private static func sanitized(_ fields: [String: String]) -> [String: String] {
        fields.reduce(into: [:]) { result, field in
            let key = String(field.key.prefix(120))
            let normalizedKey = key.lowercased()
            if sensitiveFieldFragments.contains(where: normalizedKey.contains) {
                result[key] = "<redacted>"
                return
            }
            let oneLine = field.value.replacingOccurrences(of: "\n", with: "\\n")
            result[key] = String(oneLine.prefix(maximumFieldValueLength))
        }
    }
}

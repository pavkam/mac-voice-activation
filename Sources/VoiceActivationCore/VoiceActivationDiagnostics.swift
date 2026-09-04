// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

public enum VoiceActivationDiagnosticCategory: String, Codable, Sendable {
    case app
    case settings
    case ui
    case hotKey = "hot_key"
    case speechRecognition = "speech_recognition"
    case command
    case acp
    case agent
    case audio
    case network
}

public enum VoiceActivationDiagnosticLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

public protocol VoiceActivationDiagnosticRecording: Sendable {
    func record(
        category: VoiceActivationDiagnosticCategory,
        event: String,
        level: VoiceActivationDiagnosticLevel,
        fields: [String: String])

    func flush()
}

extension VoiceActivationDiagnosticRecording {
    public func record(
        category: VoiceActivationDiagnosticCategory,
        event: String,
        fields: [String: String] = [:]
    ) {
        record(category: category, event: event, level: .info, fields: fields)
    }
}

public final class VoiceActivationDiagnostics: VoiceActivationDiagnosticRecording,
    @unchecked Sendable
{
    public static let shared = VoiceActivationDiagnostics()

    private let lock = NSLock()
    private var recorder: (any VoiceActivationDiagnosticRecording)?

    private init() {}

    public func install(_ recorder: any VoiceActivationDiagnosticRecording) {
        lock.lock()
        self.recorder = recorder
        lock.unlock()
    }

    public func record(
        category: VoiceActivationDiagnosticCategory,
        event: String,
        level: VoiceActivationDiagnosticLevel,
        fields: [String: String]
    ) {
        lock.lock()
        let recorder = recorder
        lock.unlock()
        recorder?.record(category: category, event: event, level: level, fields: fields)
    }

    public func flush() {
        lock.lock()
        let recorder = recorder
        lock.unlock()
        recorder?.flush()
    }
}

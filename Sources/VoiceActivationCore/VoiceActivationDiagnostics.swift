// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// A privacy-safe subsystem label attached to each diagnostic event.
public enum VoiceActivationDiagnosticCategory: String, Codable, Sendable {
    /// Application lifecycle and top-level state.
    case app
    /// Preference loading, migration, and saving.
    case settings
    /// Window and presentation behavior.
    case ui
    /// Global keyboard shortcut registration and delivery.
    case hotKey = "hot_key"
    /// Speech recognition and microphone-session behavior.
    case speechRecognition = "speech_recognition"
    /// Direct command validation and execution.
    case command
    /// Raw ACP connection and protocol behavior.
    case acp
    /// Agent turn and conversation orchestration.
    case agent
    /// Playback, speech synthesis, and audio-session behavior.
    case audio
    /// External synthesis service requests.
    case network
}

/// The severity attached to a diagnostic event.
public enum VoiceActivationDiagnosticLevel: String, Codable, Sendable {
    /// Detailed lifecycle data intended for diagnosis.
    case debug
    /// Expected high-level behavior.
    case info
    /// Recoverable behavior that may degrade the experience.
    case warning
    /// An operation failed or the app entered an error state.
    case error
}

/// Records bounded, redacted diagnostic metadata without retaining transcript text.
public protocol VoiceActivationDiagnosticRecording: Sendable {
    /// Records one structured diagnostic event.
    ///
    /// - Parameters:
    ///   - category: The subsystem that produced the event.
    ///   - event: A stable machine-readable event name.
    ///   - level: The event severity.
    ///   - fields: Bounded metadata that must not contain secrets or transcript text.
    func record(
        category: VoiceActivationDiagnosticCategory,
        event: String,
        level: VoiceActivationDiagnosticLevel,
        fields: [String: String])

    /// Flushes buffered events to durable storage when the recorder supports it.
    func flush()
}

extension VoiceActivationDiagnosticRecording {
    /// Records an informational diagnostic event.
    ///
    /// - Parameters:
    ///   - category: The subsystem that produced the event.
    ///   - event: A stable machine-readable event name.
    ///   - fields: Bounded privacy-safe metadata.
    public func record(
        category: VoiceActivationDiagnosticCategory,
        event: String,
        fields: [String: String] = [:]
    ) {
        record(category: category, event: event, level: .info, fields: fields)
    }
}

/// A process-wide, thread-safe forwarding hub for the installed diagnostic recorder.
public final class VoiceActivationDiagnostics: VoiceActivationDiagnosticRecording,
    @unchecked Sendable
{
    /// The process-wide diagnostics hub used by default dependencies.
    public static let shared = VoiceActivationDiagnostics()

    private let lock = NSLock()
    private var recorder: (any VoiceActivationDiagnosticRecording)?

    private init() {}

    /// Replaces the current recorder used by subsequent events.
    ///
    /// - Parameter recorder: The recorder that receives future events.
    public func install(_ recorder: any VoiceActivationDiagnosticRecording) {
        lock.lock()
        self.recorder = recorder
        lock.unlock()
    }

    /// Forwards one event to the currently installed recorder, if any.
    ///
    /// - Parameters:
    ///   - category: The subsystem that produced the event.
    ///   - event: A stable machine-readable event name.
    ///   - level: The event severity.
    ///   - fields: Bounded privacy-safe metadata.
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

    /// Flushes the currently installed recorder, if any.
    public func flush() {
        lock.lock()
        let recorder = recorder
        lock.unlock()
        recorder?.flush()
    }
}

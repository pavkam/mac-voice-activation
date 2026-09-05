// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// The recognition policy requested from a speech-session implementation.
public enum SpeechSessionMode: Equatable, Sendable {
    /// Continuously listens only for enabled wake phrases.
    case passiveWake
    /// Captures the command that follows a detected wake phrase.
    case commandCapture
    /// Captures follow-up utterances during a live agent conversation.
    case conversation
    /// Captures audio only while a configured shortcut is held.
    case pushToTalk
}

/// One partial, final, or failed recognition update.
public struct SpeechUpdate: Equatable, Sendable {
    /// The best transcript available for this update.
    public let transcript: String
    /// Whether the recognizer considers the utterance complete.
    public let isFinal: Bool
    /// A user-presentable recognition error, when recognition failed.
    public let errorDescription: String?

    /// Creates a recognition update.
    ///
    /// - Parameters:
    ///   - transcript: The partial or final recognized text.
    ///   - isFinal: Whether no more text belongs to this utterance.
    ///   - errorDescription: A failure description, or `nil` for normal updates.
    public init(transcript: String, isFinal: Bool, errorDescription: String?) {
        self.transcript = transcript
        self.isFinal = isFinal
        self.errorDescription = errorDescription
    }
}

/// Owns one microphone-backed speech-recognition session at a time.
@MainActor
public protocol SpeechSessionProtocol: AnyObject {
    /// Starts recognition and delivers updates on the main actor.
    ///
    /// - Parameters:
    ///   - mode: The recognition policy for this session.
    ///   - localeID: The speech-recognition locale identifier.
    ///   - contextualStrings: Wake phrases or vocabulary hints for the recognizer.
    ///   - onUpdate: Receives partial, final, and failed recognition updates.
    ///   - onInterruption: Runs when another audio client interrupts the session.
    /// - Throws: An implementation-specific error when audio capture cannot start.
    func start(
        mode: SpeechSessionMode,
        localeID: String,
        contextualStrings: [String],
        onUpdate: @escaping (SpeechUpdate) -> Void,
        onInterruption: @escaping () -> Void) throws

    /// Stops recognition and releases the microphone session.
    func stop()
}

/// The immutable wake-profile and locale snapshot used by the coordinator.
public struct ActivationConfiguration: Equatable, Sendable {
    /// Every configured wake profile, including disabled profiles.
    public let profiles: [WakeProfile]
    /// The locale identifier used for recognition.
    public let localeID: String

    /// Creates a configuration, substituting the default profile for an empty list.
    ///
    /// - Parameters:
    ///   - profiles: The configured wake profiles.
    ///   - localeID: The speech-recognition locale identifier.
    public init(profiles: [WakeProfile], localeID: String) {
        self.profiles = profiles.isEmpty ? [.defaultValue] : profiles
        self.localeID = localeID
    }

    /// Creates a legacy single-profile configuration.
    ///
    /// - Parameters:
    ///   - wakePhrase: The phrase that begins command capture.
    ///   - localeID: The speech-recognition locale identifier.
    ///   - commandTemplate: The command invoked with the captured transcript.
    public init(wakePhrase: String, localeID: String, commandTemplate: CommandTemplate) {
        let candidatePhrase = WakePhraseMatcher.normalizedWakePhrase(wakePhrase)
        let normalizedPhrase = !WakePhraseMatcher.containsSpokenCharacter(candidatePhrase)
            ? "computer"
            : candidatePhrase
        profiles = [try! WakeProfile(
            id: WakeProfile.defaultValue.id,
            wakePhrase: normalizedPhrase,
            executablePath: commandTemplate.executablePath,
            argumentTemplates: commandTemplate.argumentTemplates,
            accent: .blue)]
        self.localeID = localeID
    }
}

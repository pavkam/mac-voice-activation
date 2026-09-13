// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// Persists user settings and performs backward-compatible profile migration.
public final class AppPreferences {
    private enum Key {
        static let passiveEnabled = "passiveEnabled"
        static let capturesMacContext = "capturesMacContext"
        static let readsAgentRepliesAloud = "readsAgentRepliesAloud"
        static let playsAgentWorkingSound = "playsAgentWorkingSound"
        static let agentSpeechProvider = "agentSpeechProvider"
        static let elevenLabsVoiceID = "elevenLabsVoiceID"
        static let defaultSpeechVoice = "defaultSpeechVoice"
        static let wakePhrase = "wakePhrase"
        static let wakeProfiles = "wakeProfiles"
        static let localeID = "localeID"
        static let pushToTalkKeyCode = "pushToTalkKeyCode"
        static let pushToTalkModifiers = "pushToTalkModifiers"
        static let pushToTalkKeyLabel = "pushToTalkKeyLabel"
        static let profileHotKeysMigrated = "profileHotKeysMigrated"
        static let executablePath = "executablePath"
        static let argumentTemplates = "argumentTemplates"
        static let hasCompletedFirstRun = "hasCompletedFirstRun"
        static let terminalPhrases = "terminalPhrases"
    }

    private let defaults: UserDefaults

    /// Creates a preferences store over the supplied defaults domain.
    ///
    /// - Parameter defaults: The defaults domain used for all persisted values.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether passive wake-phrase listening should run when possible.
    public var passiveEnabled: Bool {
        get {
            defaults.object(forKey: Key.passiveEnabled) == nil
                ? true
                : defaults.bool(forKey: Key.passiveEnabled)
        }
        set { defaults.set(newValue, forKey: Key.passiveEnabled) }
    }

    /// Whether admitted ACP requests include a bounded snapshot of the focused Mac context.
    public var capturesMacContext: Bool {
        get {
            defaults.object(forKey: Key.capturesMacContext) == nil
                ? true
                : defaults.bool(forKey: Key.capturesMacContext)
        }
        set { defaults.set(newValue, forKey: Key.capturesMacContext) }
    }

    /// Whether complete streamed agent thoughts are queued for speech synthesis.
    public var readsAgentRepliesAloud: Bool {
        get {
            defaults.object(forKey: Key.readsAgentRepliesAloud) == nil
                ? true
                : defaults.bool(forKey: Key.readsAgentRepliesAloud)
        }
        set { defaults.set(newValue, forKey: Key.readsAgentRepliesAloud) }
    }

    /// Whether an unobtrusive activity loop plays while the agent is silent and working.
    public var playsAgentWorkingSound: Bool {
        get {
            defaults.object(forKey: Key.playsAgentWorkingSound) == nil
                ? true
                : defaults.bool(forKey: Key.playsAgentWorkingSound)
        }
        set { defaults.set(newValue, forKey: Key.playsAgentWorkingSound) }
    }

    /// The text-to-speech provider selected for agent replies.
    public var agentSpeechProvider: AgentSpeechProvider {
        get {
            guard let rawValue = defaults.string(forKey: Key.agentSpeechProvider) else {
                return .system
            }
            return AgentSpeechProvider(rawValue: rawValue) ?? .system
        }
        set { defaults.set(newValue.rawValue, forKey: Key.agentSpeechProvider) }
    }

    /// The ElevenLabs voice identifier used for cloud speech synthesis.
    public var elevenLabsVoiceID: String {
        get {
            normalized(
                defaults.string(forKey: Key.elevenLabsVoiceID),
                fallback: "JBFqnCBsd6RMkjVDRZzb")
        }
        set {
            defaults.set(
                normalized(newValue, fallback: "JBFqnCBsd6RMkjVDRZzb"),
                forKey: Key.elevenLabsVoiceID)
        }
    }

    /// The app-wide backend and voice inherited by profiles without an override.
    public var defaultSpeechVoice: TextToSpeechVoiceSelection {
        get {
            if let data = defaults.data(forKey: Key.defaultSpeechVoice),
                let selection = try? JSONDecoder().decode(
                    TextToSpeechVoiceSelection.self,
                    from: data)
            {
                return selection
            }
            switch agentSpeechProvider {
            case .system:
                return TextToSpeechVoiceSelection(backendID: .system, voiceID: nil)
            case .elevenLabs:
                return TextToSpeechVoiceSelection(
                    backendID: .elevenLabs,
                    voiceID: elevenLabsVoiceID)
            }
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.defaultSpeechVoice)
            }
        }
    }

    /// The legacy single-profile wake phrase retained for settings migration.
    public var wakePhrase: String {
        get { normalized(defaults.string(forKey: Key.wakePhrase), fallback: "computer") }
        set { defaults.set(normalized(newValue, fallback: "computer"), forKey: Key.wakePhrase) }
    }

    /// The persisted wake profiles, with legacy shortcut migration applied once.
    public var wakeProfiles: [WakeProfile] {
        get {
            guard let data = defaults.data(forKey: Key.wakeProfiles) else {
                return profilesWithMigratedHotKey([legacyWakeProfile()])
            }

            guard
                let profiles = try? JSONDecoder().decode([WakeProfile].self, from: data),
                !profiles.isEmpty
            else {
                return [legacyWakeProfile()]
            }

            return profilesWithMigratedHotKey(profiles)
        }
        set {
            let profiles = newValue.isEmpty ? [WakeProfile.defaultValue] : newValue
            storeWakeProfiles(profiles)
            defaults.set(true, forKey: Key.profileHotKeysMigrated)
        }
    }

    /// The locale identifier used by speech recognition.
    public var localeID: String {
        get { normalized(defaults.string(forKey: Key.localeID), fallback: Locale.current.identifier) }
        set { defaults.set(normalized(newValue, fallback: Locale.current.identifier), forKey: Key.localeID) }
    }

    /// The legacy single-profile executable path retained for migration.
    public var executablePath: String {
        get { normalized(defaults.string(forKey: Key.executablePath), fallback: "/usr/bin/open") }
        set { defaults.set(normalized(newValue, fallback: "/usr/bin/open"), forKey: Key.executablePath) }
    }

    /// The legacy global push-to-talk shortcut retained for profile migration.
    public var pushToTalkHotKey: PushToTalkHotKey {
        get {
            guard
                defaults.object(forKey: Key.pushToTalkKeyCode) != nil,
                defaults.object(forKey: Key.pushToTalkModifiers) != nil,
                let keyLabel = defaults.string(forKey: Key.pushToTalkKeyLabel),
                let hotKey = try? PushToTalkHotKey(
                    keyCode: UInt32(defaults.integer(forKey: Key.pushToTalkKeyCode)),
                    modifiers: HotKeyModifiers(
                        rawValue: UInt32(defaults.integer(forKey: Key.pushToTalkModifiers))),
                    keyLabel: keyLabel)
            else {
                return .defaultValue
            }
            return hotKey
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Key.pushToTalkKeyCode)
            defaults.set(Int(newValue.modifiers.rawValue), forKey: Key.pushToTalkModifiers)
            defaults.set(newValue.keyLabel, forKey: Key.pushToTalkKeyLabel)
        }
    }

    /// The legacy single-profile argument templates retained for migration.
    public var argumentTemplates: [String] {
        get {
            defaults.stringArray(forKey: Key.argumentTemplates)
                ?? ["https://www.google.com/search?q={urlText}"]
        }
        set { defaults.set(newValue, forKey: Key.argumentTemplates) }
    }

    /// The spoken phrases that end a live agent conversation and close its panel.
    ///
    /// Matched against the *entire* utterance, case- and diacritic-insensitive,
    /// so "thanks" ends things but "thanks for that" does not — the same
    /// precision the existing "cancel"/"stop"/"dismiss" words already had.
    /// Defaults to `Self.defaultTerminalPhrases` until the user edits the list
    /// in Settings; an explicitly saved empty list stays empty rather than
    /// falling back, so clearing every phrase is a real, honoured choice.
    public var terminalPhrases: [String] {
        get {
            defaults.array(forKey: Key.terminalPhrases) as? [String]
                ?? Self.defaultTerminalPhrases
        }
        set { defaults.set(newValue, forKey: Key.terminalPhrases) }
    }

    /// The built-in phrase list before any user edit.
    ///
    /// "cancel", "stop" and "dismiss" were the app's original spoken
    /// cancellation words; the rest are natural ways of saying a conversation
    /// is done.
    public static let defaultTerminalPhrases = [
        "cancel", "stop", "dismiss", "close",
        "thanks", "thank you", "that's it", "that'll do", "great",
    ]

    /// Whether the first-run flow has been shown and dismissed.
    ///
    /// The lazy permission model — request Microphone and Speech Recognition on
    /// the first spoken command — is unchanged by this. First run explains that
    /// model; it does not front-load the request.
    public var hasCompletedFirstRun: Bool {
        get { defaults.bool(forKey: Key.hasCompletedFirstRun) }
        set { defaults.set(newValue, forKey: Key.hasCompletedFirstRun) }
    }

    private func normalized(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func legacyWakeProfile() -> WakeProfile {
        (try? WakeProfile(
            id: WakeProfile.defaultValue.id,
            wakePhrase: wakePhrase,
            executablePath: executablePath,
            argumentTemplates: argumentTemplates,
            accent: .blue)) ?? .defaultValue
    }

    private func profilesWithMigratedHotKey(_ profiles: [WakeProfile]) -> [WakeProfile] {
        guard !defaults.bool(forKey: Key.profileHotKeysMigrated) else { return profiles }
        var migrated = profiles
        migrated[0].pushToTalkHotKey = pushToTalkHotKey
        storeWakeProfiles(migrated)
        defaults.set(true, forKey: Key.profileHotKeysMigrated)
        return migrated
    }

    private func storeWakeProfiles(_ profiles: [WakeProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Key.wakeProfiles)
        }
    }
}

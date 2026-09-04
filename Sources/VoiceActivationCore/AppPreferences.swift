// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

public final class AppPreferences {
    private enum Key {
        static let passiveEnabled = "passiveEnabled"
        static let readsAgentRepliesAloud = "readsAgentRepliesAloud"
        static let playsAgentWorkingSound = "playsAgentWorkingSound"
        static let agentSpeechProvider = "agentSpeechProvider"
        static let elevenLabsVoiceID = "elevenLabsVoiceID"
        static let wakePhrase = "wakePhrase"
        static let wakeProfiles = "wakeProfiles"
        static let localeID = "localeID"
        static let pushToTalkKeyCode = "pushToTalkKeyCode"
        static let pushToTalkModifiers = "pushToTalkModifiers"
        static let pushToTalkKeyLabel = "pushToTalkKeyLabel"
        static let profileHotKeysMigrated = "profileHotKeysMigrated"
        static let executablePath = "executablePath"
        static let argumentTemplates = "argumentTemplates"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var passiveEnabled: Bool {
        get {
            defaults.object(forKey: Key.passiveEnabled) == nil
                ? true
                : defaults.bool(forKey: Key.passiveEnabled)
        }
        set { defaults.set(newValue, forKey: Key.passiveEnabled) }
    }

    public var readsAgentRepliesAloud: Bool {
        get {
            defaults.object(forKey: Key.readsAgentRepliesAloud) == nil
                ? true
                : defaults.bool(forKey: Key.readsAgentRepliesAloud)
        }
        set { defaults.set(newValue, forKey: Key.readsAgentRepliesAloud) }
    }

    public var playsAgentWorkingSound: Bool {
        get {
            defaults.object(forKey: Key.playsAgentWorkingSound) == nil
                ? true
                : defaults.bool(forKey: Key.playsAgentWorkingSound)
        }
        set { defaults.set(newValue, forKey: Key.playsAgentWorkingSound) }
    }

    public var agentSpeechProvider: AgentSpeechProvider {
        get {
            guard let rawValue = defaults.string(forKey: Key.agentSpeechProvider) else {
                return .system
            }
            return AgentSpeechProvider(rawValue: rawValue) ?? .system
        }
        set { defaults.set(newValue.rawValue, forKey: Key.agentSpeechProvider) }
    }

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

    public var wakePhrase: String {
        get { normalized(defaults.string(forKey: Key.wakePhrase), fallback: "computer") }
        set { defaults.set(normalized(newValue, fallback: "computer"), forKey: Key.wakePhrase) }
    }

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

    public var localeID: String {
        get { normalized(defaults.string(forKey: Key.localeID), fallback: Locale.current.identifier) }
        set { defaults.set(normalized(newValue, fallback: Locale.current.identifier), forKey: Key.localeID) }
    }

    public var executablePath: String {
        get { normalized(defaults.string(forKey: Key.executablePath), fallback: "/usr/bin/open") }
        set { defaults.set(normalized(newValue, fallback: "/usr/bin/open"), forKey: Key.executablePath) }
    }

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

    public var argumentTemplates: [String] {
        get {
            defaults.stringArray(forKey: Key.argumentTemplates)
                ?? ["https://www.google.com/search?q={urlText}"]
        }
        set { defaults.set(newValue, forKey: Key.argumentTemplates) }
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

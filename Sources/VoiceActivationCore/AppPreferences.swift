import Foundation

public final class AppPreferences {
    private enum Key {
        static let passiveEnabled = "passiveEnabled"
        static let wakePhrase = "wakePhrase"
        static let localeID = "localeID"
        static let pushToTalkKeyCode = "pushToTalkKeyCode"
        static let pushToTalkModifiers = "pushToTalkModifiers"
        static let pushToTalkKeyLabel = "pushToTalkKeyLabel"
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

    public var wakePhrase: String {
        get { normalized(defaults.string(forKey: Key.wakePhrase), fallback: "computer") }
        set { defaults.set(normalized(newValue, fallback: "computer"), forKey: Key.wakePhrase) }
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
}

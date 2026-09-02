import Foundation

public struct HotKeyModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    public static let control = HotKeyModifiers(rawValue: 1 << 0)
    public static let option = HotKeyModifiers(rawValue: 1 << 1)
    public static let shift = HotKeyModifiers(rawValue: 1 << 2)
    public static let command = HotKeyModifiers(rawValue: 1 << 3)

    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public struct PushToTalkHotKey: Codable, Equatable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, LocalizedError {
        case modifierRequired
        case keyRequired

        public var errorDescription: String? {
            switch self {
            case .modifierRequired:
                "Push to talk requires at least one modifier key."
            case .keyRequired:
                "Push to talk requires a keyboard key."
            }
        }
    }

    public static let defaultValue = try! PushToTalkHotKey(
        keyCode: 49,
        modifiers: [.control, .option],
        keyLabel: "Space")

    public let keyCode: UInt32
    public let modifiers: HotKeyModifiers
    public let keyLabel: String

    public var displayName: String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        return value + keyLabel
    }

    public init(keyCode: UInt32, modifiers: HotKeyModifiers, keyLabel: String) throws {
        guard !modifiers.isEmpty else { throw ValidationError.modifierRequired }
        let normalizedLabel = keyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else { throw ValidationError.keyRequired }

        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = normalizedLabel
    }
}

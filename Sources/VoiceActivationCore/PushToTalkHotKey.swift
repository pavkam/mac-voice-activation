// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// The supported global-shortcut modifiers stored independently of AppKit.
public struct HotKeyModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    /// The Control modifier.
    public static let control = HotKeyModifiers(rawValue: 1 << 0)
    /// The Option modifier.
    public static let option = HotKeyModifiers(rawValue: 1 << 1)
    /// The Shift modifier.
    public static let shift = HotKeyModifiers(rawValue: 1 << 2)
    /// The Command modifier.
    public static let command = HotKeyModifiers(rawValue: 1 << 3)

    /// The stable bit field used for persistence and Carbon conversion.
    public let rawValue: UInt32

    /// Creates a modifier set from its stable bit representation.
    ///
    /// - Parameter rawValue: The persisted modifier bits.
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// A validated physical key and modifier combination for one wake profile.
public struct PushToTalkHotKey: Codable, Equatable, Hashable, Sendable {
    /// Failures that prevent a shortcut from being globally distinguishable.
    public enum ValidationError: Error, Equatable, LocalizedError {
        /// No modifier key was selected.
        case modifierRequired
        /// The display label does not contain a keyboard key.
        case keyRequired

        /// A user-presentable explanation of the invalid shortcut.
        public var errorDescription: String? {
            switch self {
            case .modifierRequired:
                "Push to talk requires at least one modifier key."
            case .keyRequired:
                "Push to talk requires a keyboard key."
            }
        }
    }

    /// The initial Control-Option-Space shortcut supplied to new profiles.
    public static let defaultValue = try! PushToTalkHotKey(
        keyCode: 49,
        modifiers: [.control, .option],
        keyLabel: "Space")

    /// The hardware-independent macOS virtual key code.
    public let keyCode: UInt32
    /// The required modifier combination.
    public let modifiers: HotKeyModifiers
    /// The localized display label captured when the shortcut was recorded.
    public let keyLabel: String

    /// A compact glyph representation suitable for menus and Settings.
    public var displayName: String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        return value + keyLabel
    }

    /// Creates a validated push-to-talk shortcut.
    ///
    /// - Parameters:
    ///   - keyCode: The macOS virtual key code.
    ///   - modifiers: At least one modifier that disambiguates the global shortcut.
    ///   - keyLabel: A nonempty label shown to the user.
    /// - Throws: ``ValidationError`` when the modifier set or key label is empty.
    public init(keyCode: UInt32, modifiers: HotKeyModifiers, keyLabel: String) throws {
        guard !modifiers.isEmpty else { throw ValidationError.modifierRequired }
        let normalizedLabel = keyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else { throw ValidationError.keyRequired }

        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = normalizedLabel
    }
}

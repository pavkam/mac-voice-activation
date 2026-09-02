import AppKit
import Carbon.HIToolbox
import VoiceActivationCore

enum HotKeyEventConverter {
    static func convert(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?) -> PushToTalkHotKey?
    {
        var modifiers: HotKeyModifiers = []
        if modifierFlags.contains(.control) { modifiers.insert(.control) }
        if modifierFlags.contains(.option) { modifiers.insert(.option) }
        if modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if modifierFlags.contains(.command) { modifiers.insert(.command) }

        guard !modifiers.isEmpty, let keyLabel = label(
            keyCode: keyCode,
            charactersIgnoringModifiers: charactersIgnoringModifiers)
        else {
            return nil
        }

        return try? PushToTalkHotKey(
            keyCode: UInt32(keyCode),
            modifiers: modifiers,
            keyLabel: keyLabel)
    }

    private static func label(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?) -> String?
    {
        let specialLabels: [Int: String] = [
            kVK_Space: "Space",
            kVK_Return: "Return",
            kVK_Tab: "Tab",
            kVK_Escape: "Esc",
            kVK_Delete: "Delete",
            kVK_ForwardDelete: "⌦",
            kVK_Home: "Home",
            kVK_End: "End",
            kVK_PageUp: "Page Up",
            kVK_PageDown: "Page Down",
            kVK_LeftArrow: "←",
            kVK_RightArrow: "→",
            kVK_UpArrow: "↑",
            kVK_DownArrow: "↓",
            kVK_F1: "F1",
            kVK_F2: "F2",
            kVK_F3: "F3",
            kVK_F4: "F4",
            kVK_F5: "F5",
            kVK_F6: "F6",
            kVK_F7: "F7",
            kVK_F8: "F8",
            kVK_F9: "F9",
            kVK_F10: "F10",
            kVK_F11: "F11",
            kVK_F12: "F12",
            kVK_F13: "F13",
            kVK_F14: "F14",
            kVK_F15: "F15",
            kVK_F16: "F16",
            kVK_F17: "F17",
            kVK_F18: "F18",
            kVK_F19: "F19",
            kVK_F20: "F20",
        ]
        if let specialLabel = specialLabels[Int(keyCode)] {
            return specialLabel
        }

        let value = charactersIgnoringModifiers?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        return value.isEmpty ? nil : value
    }
}

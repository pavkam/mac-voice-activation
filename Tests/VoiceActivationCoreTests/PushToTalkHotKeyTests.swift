import Testing
@testable import VoiceActivationCore

struct PushToTalkHotKeyTests {
    @Test func displayName_WhenModifiersAndKeyArePresent_UsesMacSymbols() throws {
        let hotKey = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.control, .option, .shift, .command],
            keyLabel: "K")

        #expect(hotKey.displayName == "⌃⌥⇧⌘K")
    }

    @Test func init_WhenNoModifierIsPresent_ThrowsValidationError() {
        #expect(throws: PushToTalkHotKey.ValidationError.modifierRequired) {
            try PushToTalkHotKey(keyCode: 40, modifiers: [], keyLabel: "K")
        }
    }

    @Test func init_WhenKeyLabelIsBlank_ThrowsValidationError() {
        #expect(throws: PushToTalkHotKey.ValidationError.keyRequired) {
            try PushToTalkHotKey(keyCode: 40, modifiers: [.control], keyLabel: "  ")
        }
    }
}

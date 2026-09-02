import Carbon.HIToolbox
import Testing
@testable import VoiceActivationApp
import VoiceActivationCore

struct PushToTalkShortcutTests {
    @MainActor @Test func carbonModifiers_WhenAllSupportedModifiersArePresent_MapsEveryModifier() {
        let modifiers = PushToTalkShortcut.carbonModifiers(
            for: [.control, .option, .shift, .command])

        #expect(modifiers == UInt32(controlKey | optionKey | shiftKey | cmdKey))
    }
}

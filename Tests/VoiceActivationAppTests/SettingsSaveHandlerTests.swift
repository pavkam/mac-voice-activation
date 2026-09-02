import Testing
@testable import VoiceActivationApp

struct SettingsSaveHandlerTests {
    @Test func perform_WhenSaveSucceeds_ClosesSettings() {
        var closeCount = 0

        let saved = SettingsSaveHandler.perform(
            save: { true },
            close: { closeCount += 1 })

        #expect(saved)
        #expect(closeCount == 1)
    }

    @Test func perform_WhenSaveFails_KeepsSettingsOpen() {
        var closeCount = 0

        let saved = SettingsSaveHandler.perform(
            save: { false },
            close: { closeCount += 1 })

        #expect(!saved)
        #expect(closeCount == 0)
    }
}

import Testing
@testable import VoiceActivationApp

struct SettingsSaveHandlerTests {
    @MainActor @Test func perform_WhenSaveSucceeds_ClosesSettings() async {
        var closeCount = 0

        let saved = await SettingsSaveHandler.perform(
            save: { true },
            close: { closeCount += 1 })

        #expect(saved)
        #expect(closeCount == 1)
    }

    @MainActor @Test func perform_WhenSaveFails_KeepsSettingsOpen() async {
        var closeCount = 0

        let saved = await SettingsSaveHandler.perform(
            save: { false },
            close: { closeCount += 1 })

        #expect(!saved)
        #expect(closeCount == 0)
    }

    @MainActor @Test func perform_WhenAgentSaveSucceeds_ClosesOnlyAfterAsyncSaveCompletes() async {
        var events: [String] = []

        _ = await SettingsSaveHandler.perform(
            save: {
                await Task.yield()
                events.append("agent reset")
                return true
            },
            close: { events.append("close") })

        #expect(events == ["agent reset", "close"])
    }

    @MainActor @Test func perform_WhenAgentSaveFails_DoesNotCloseSettings() async {
        var closeCount = 0

        let saved = await SettingsSaveHandler.perform(
            save: {
                await Task.yield()
                return false
            },
            close: { closeCount += 1 })

        #expect(!saved)
        #expect(closeCount == 0)
    }
}

import Testing
@testable import VoiceActivationApp

struct SettingsWindowPresenterTests {
    @MainActor
    @Test
    func open_WhenInvoked_ActivatesApplicationBeforeOpeningWindow() {
        var events: [String] = []
        let presenter = SettingsWindowPresenter {
            events.append("activate")
        }

        presenter.open {
            events.append("open")
        }

        #expect(events == ["activate", "open"])
    }
}

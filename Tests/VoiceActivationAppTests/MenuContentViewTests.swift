import SwiftUI
import Testing
import VoiceActivationCore
@testable import VoiceActivationApp

@MainActor
private final class MenuOverlayStub: RecordingOverlayDisplaying {
    var onCancel: (() -> Void)?

    func show(transcript: String, accent: WakeProfileAccent) {}
    func hide() {}
}

struct MenuContentViewTests {
    @MainActor @Test func render_WhenManyProfilesExist_KeepsPanelHeightBounded() throws {
        let suite = "VoiceActivationMenuLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        preferences.wakeProfiles = try (1...20).map { index in
            try WakeProfile(
                wakePhrase: "profile \(index)",
                urlTemplate: "https://example.com/?q={urlText}",
                accent: WakeProfileAccent.allCases[index % WakeProfileAccent.allCases.count])
        }
        let model = AppModel(
            preferences: preferences,
            recordingOverlay: MenuOverlayStub(),
            startsAutomatically: false)
        let renderer = ImageRenderer(content: MenuContentView(model: model))

        let image = try #require(renderer.cgImage)

        #expect(image.height <= 600)
    }
}

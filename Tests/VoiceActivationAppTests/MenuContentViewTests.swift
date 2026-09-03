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
    @Test func listeningControl_WhenListening_OffersPauseAll() {
        let presentation = MenuListeningControlPresentation.make(isListening: true)

        #expect(presentation.title == "Pause all")
        #expect(presentation.symbolName == "pause.circle.fill")
    }

    @Test func listeningControl_WhenPaused_OffersResumeAll() {
        let presentation = MenuListeningControlPresentation.make(isListening: false)

        #expect(presentation.title == "Resume all")
        #expect(presentation.symbolName == "play.circle.fill")
    }

    @MainActor @Test func render_WhenMenuHostProposesNoHeight_KeepsProfileRowsVisible() throws {
        let oneProfileRenderer = ImageRenderer(content: MenuContentView(model: try model(profileCount: 1)))
        let twoProfileRenderer = ImageRenderer(content: MenuContentView(model: try model(profileCount: 2)))
        oneProfileRenderer.proposedSize = ProposedViewSize(width: 356, height: 0)
        twoProfileRenderer.proposedSize = ProposedViewSize(width: 356, height: 0)

        let oneProfileImage = try #require(oneProfileRenderer.cgImage)
        let twoProfileImage = try #require(twoProfileRenderer.cgImage)

        #expect(twoProfileImage.height >= oneProfileImage.height + 40)
    }

    @Test func profileListHeight_WhenTwoProfilesExist_ShowsBothRows() {
        #expect(MenuProfileListLayout.height(profileCount: 2) == 107)
    }

    @Test func profileListHeight_WhenProfilesExceedViewport_CapsHeight() {
        #expect(MenuProfileListLayout.height(profileCount: 20) == 360)
    }

    @MainActor @Test func render_WhenManyProfilesExist_KeepsPanelHeightBounded() throws {
        let model = try model(profileCount: 20)
        let renderer = ImageRenderer(content: MenuContentView(model: model))

        let image = try #require(renderer.cgImage)

        #expect(image.height <= 600)
    }

    @MainActor private func model(profileCount: Int) throws -> AppModel {
        let suite = "VoiceActivationMenuLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults)
        preferences.wakeProfiles = try (1...profileCount).map { index in
            try WakeProfile(
                wakePhrase: "profile \(index)",
                urlTemplate: "https://example.com/?q={urlText}",
                accent: WakeProfileAccent.allCases[index % WakeProfileAccent.allCases.count])
        }
        return AppModel(
            preferences: preferences,
            recordingOverlay: MenuOverlayStub(),
            soundPlayer: SilentCaptureSoundPlayer(),
            startsAutomatically: false)
    }
}

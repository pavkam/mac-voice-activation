// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import Testing
import YapOpsCore
@testable import YapOpsApp

@MainActor
private final class MenuOverlayStub: RecordingOverlayDisplaying {
    var onCancel: (() -> Void)?

    func show(transcript: String, accent: WakeProfileAccent, levels: [Double]) {}
    func hide() {}
}

struct MenuContentViewTests {
    private static let childEnvironmentKey =
        "YAPOPS_MENU_SHADOW_TEST_CHILD"
    private static let testFilter =
        "render_WhenConversationControlsCollapse_LeavesNoSystemWindowShadow"

    @MainActor @Test func status_WhenListeningIsRequestedBeforeCoordinatorStarts_ShowsStarting() throws {
        let model = try model(profileCount: 2)

        let presentation = model.statusPresentation

        #expect(presentation.title == "Starting")
        #expect(presentation.detail == "Preparing wake phrase listening")
    }

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

    @MainActor @Test
    func userMessage_WhenQueued_RendersTransportCaptionAndAccessibilityValue() throws {
        let model = AgentRunPanelModel()
        let message = AgentUserMessagePresentation(
            id: UUID(),
            text: "also add tests",
            disposition: .queued)
        let block = AgentRunPanelView(model: model).userMessageBlock(
            message)
        let renderer = ImageRenderer(content: block)
        renderer.proposedSize = ProposedViewSize(width: 320, height: nil)
        #expect(renderer.cgImage != nil)
        #expect(message.transportPresentation?.caption == "Queued for next turn")
        #expect(message.transportPresentation?.accessibilityLabel == "Delivery status")
        #expect(message.transportPresentation?.accessibilityValue == "Queued for next turn")
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func render_WhenConversationControlsCollapse_LeavesNoSystemWindowShadow() async throws {
        guard ProcessInfo.processInfo.environment[Self.childEnvironmentKey] == "1" else {
            try await IsolatedAppKitTestProcess.run(
                environmentKey: Self.childEnvironmentKey,
                testFilter: Self.testFilter)
            return
        }

        let model = try model(profileCount: 2)
        let profile = try #require(model.activeWakeProfiles.first)
        let runID = UUID()
        model.handleAgentRunLifecycleEvent(
            .started(runID: runID, profile: profile, prompt: "Show a picture"))
        model.handleAgentRunLifecycleEvent(
            .completed(
                runID: runID,
                result: AgentRunResult(stopReason: .endTurn)))
        let hostingView = NSHostingView(rootView: MenuContentView(model: model))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        // Swift owns this window; close must not release it a second time.
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.hasShadow = true
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        #expect(window.hasShadow == false)

        window.hasShadow = true
        model.deleteAgentRun()
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))

        #expect(model.agentRunSnapshot == nil)
        #expect(window.hasShadow == false)
    }

    @MainActor private func model(profileCount: Int) throws -> AppModel {
        let suite = InMemoryDefaults.makeSuiteName("YapOpsMenuLayoutTests")
        let defaults = try #require(InMemoryDefaults(suiteName: suite))
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
            agentConversationAudioPlayer: SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: SilentAgentSpeechCredentialStore(),
            startsAutomatically: false)
    }

}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import Testing
import VoiceActivationCore
@testable import VoiceActivationApp

@MainActor
private final class RecordingOverlayDisplaySpy: RecordingOverlayDisplaying {
    private(set) var shownValues: [(String, WakeProfileAccent)] = []
    private(set) var hideCount = 0
    private(set) var handoffCount = 0
    var handoff: RecordingOverlayHandoff?
    var onCancel: (() -> Void)?

    func show(transcript: String, accent: WakeProfileAccent) {
        shownValues.append((transcript, accent))
    }

    func hide() {
        hideCount += 1
    }

    func takeAgentRunHandoff() -> RecordingOverlayHandoff? {
        handoffCount += 1
        return handoff
    }

    func requestCancel() {
        onCancel?()
    }
}

struct RecordingOverlayPresenterTests {
    @MainActor
    @Test
    func update_WhenCapturing_ShowsLiveTranscript() {
        let display = RecordingOverlayDisplaySpy()
        let presenter = RecordingOverlayPresenter(display: display)

        presenter.update(state: .capturing, transcript: "open calendar", accent: .purple)

        #expect(display.shownValues.first?.0 == "open calendar")
        #expect(display.shownValues.first?.1 == .purple)
        #expect(display.hideCount == 0)
    }

    @MainActor
    @Test
    func cancel_WhenDisplayRequestsCancellation_InvokesHandler() {
        let display = RecordingOverlayDisplaySpy()
        let presenter = RecordingOverlayPresenter(display: display)
        var cancellationCount = 0
        presenter.onCancel = {
            cancellationCount += 1
        }

        display.requestCancel()

        #expect(cancellationCount == 1)
    }

    @MainActor
    @Test(arguments: [
        ActivationState.disabled,
        .listening,
        .executing,
        .failed("microphone unavailable"),
    ])
    func update_WhenNotCapturing_HidesOverlay(state: ActivationState) {
        let display = RecordingOverlayDisplaySpy()
        let presenter = RecordingOverlayPresenter(display: display)

        presenter.update(state: state, transcript: "ignored", accent: .blue)

        #expect(display.shownValues.isEmpty)
        #expect(display.hideCount == 1)
    }

    @MainActor @Test func handoff_WhenRequested_ForwardsTheExactDisplayGeometry() {
        let display = RecordingOverlayDisplaySpy()
        let expected = RecordingOverlayHandoff(
            visibleScreenFrame: NSRect(x: -1_920, y: 24, width: 1_920, height: 1_056),
            sourceFrame: NSRect(x: -1_100, y: 66, width: 464, height: 118))
        display.handoff = expected
        let presenter = RecordingOverlayPresenter(display: display)

        let actual = presenter.takeAgentRunHandoff()

        #expect(actual == expected)
        #expect(display.handoffCount == 1)
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Testing
import VoiceActivationCore
@testable import VoiceActivationApp

@MainActor
private final class CaptureSoundSpy: CaptureSoundPlaying {
    private(set) var events: [CaptureSoundEvent] = []

    func play(_ event: CaptureSoundEvent) {
        events.append(event)
    }
}

@MainActor
private final class CaptureSoundAssetSpy: CaptureSoundAssetPlaying {
    var bundledResult = true
    private(set) var bundledNames: [String] = []
    private(set) var systemNames: [String] = []

    func playBundled(named name: String) -> Bool {
        bundledNames.append(name)
        return bundledResult
    }

    func playSystem(named name: String) {
        systemNames.append(name)
    }
}

struct CaptureSoundPresenterTests {
    @MainActor @Test func play_WhenCustomCuesExist_UsesBundledStartAndEndSounds() {
        let assets = CaptureSoundAssetSpy()
        let player = SystemCaptureSoundPlayer(assetPlayer: assets)

        player.play(.started)
        player.play(.ended)

        #expect(assets.bundledNames == ["CaptureStart", "CaptureEnd"])
        #expect(assets.systemNames.isEmpty)
    }

    @MainActor @Test func play_WhenCustomCueIsMissing_UsesSystemFallback() {
        let assets = CaptureSoundAssetSpy()
        assets.bundledResult = false
        let player = SystemCaptureSoundPlayer(assetPlayer: assets)

        player.play(.started)
        player.play(.ended)

        #expect(assets.systemNames == ["Pop", "Tink"])
    }

    @MainActor @Test func update_WhenCaptureStartsAndStops_PlaysBothCuesOnce() {
        let player = CaptureSoundSpy()
        let presenter = CaptureSoundPresenter(player: player)

        presenter.update(state: .listening)
        presenter.update(state: .capturing)
        presenter.update(state: .capturing)
        presenter.update(state: .executing)

        #expect(player.events == [.started, .ended])
    }

    @MainActor @Test func update_WhenNeverCapturing_PlaysNoCue() {
        let player = CaptureSoundSpy()
        let presenter = CaptureSoundPresenter(player: player)

        presenter.update(state: .listening)
        presenter.update(state: .failed("unavailable"))
        presenter.update(state: .disabled)

        #expect(player.events.isEmpty)
    }
}

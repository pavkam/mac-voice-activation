// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Testing
@testable import VoiceActivationApp

@MainActor
private final class AgentActivitySoundAssetSpy: AgentActivitySoundAssetPlaying {
    var bundledResult = true
    private(set) var bundledRequests: [(name: String, volume: Float)] = []
    private(set) var systemNames: [String] = []
    private(set) var stopCount = 0

    func playBundled(named name: String, volume: Float) -> Bool {
        bundledRequests.append((name, volume))
        return bundledResult
    }

    func playSystem(named name: String) {
        systemNames.append(name)
    }

    func stop() {
        stopCount += 1
    }
}

struct AgentActivitySoundPlayerTests {
    @MainActor @Test func play_WhenCustomEffectsExist_UsesTheDedicatedSoundPalette() {
        let assets = AgentActivitySoundAssetSpy()
        let player = SystemAgentActivitySoundPlayer(assetPlayer: assets)

        player.play(.thinking)
        player.play(.toolStarted)
        player.play(.toolCompleted)
        player.play(.toolFailed)

        #expect(assets.bundledRequests.map(\.name) == [
            "AgentThinking", "ToolStart", "ToolComplete", "ToolFailed",
        ])
        #expect(assets.bundledRequests.map(\.volume) == [0.70, 0.42, 0.42, 0.42])
        #expect(assets.systemNames.isEmpty)
    }

    @MainActor @Test func play_WhenCustomEffectsAreUnavailable_UsesDistinctSystemFallbacks() {
        let assets = AgentActivitySoundAssetSpy()
        assets.bundledResult = false
        let player = SystemAgentActivitySoundPlayer(assetPlayer: assets)

        player.play(.thinking)
        player.play(.toolStarted)
        player.play(.toolCompleted)
        player.play(.toolFailed)

        #expect(assets.systemNames == ["Pop", "Morse", "Tink", "Basso"])
    }

    @MainActor @Test func stop_WhenAnEffectMayBePlaying_StopsTheAssetPlayer() {
        let assets = AgentActivitySoundAssetSpy()
        let player = SystemAgentActivitySoundPlayer(assetPlayer: assets)

        player.stop()

        #expect(assets.stopCount == 1)
    }
}

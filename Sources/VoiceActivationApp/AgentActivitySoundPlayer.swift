// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit

enum AgentActivitySound: Equatable {
    case thinking
    case toolStarted
    case toolCompleted
    case toolFailed
}

@MainActor
protocol AgentActivitySoundPlaying: AnyObject {
    func play(_ sound: AgentActivitySound)
    func stop()
}

@MainActor
protocol AgentActivitySoundAssetPlaying: AnyObject {
    func playBundled(named name: String, volume: Float) -> Bool
    func playSystem(named name: String)
    func stop()
}

@MainActor
final class AppAgentActivitySoundAssets: AgentActivitySoundAssetPlaying {
    private var sounds: [String: NSSound] = [:]
    private var currentSound: NSSound?

    func playBundled(named name: String, volume: Float) -> Bool {
        let sound: NSSound
        if let cachedSound = sounds[name] {
            sound = cachedSound
        } else {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
                  let loadedSound = NSSound(contentsOf: url, byReference: true)
            else { return false }
            sounds[name] = loadedSound
            sound = loadedSound
        }
        sound.volume = volume
        play(sound)
        return true
    }

    func playSystem(named name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        play(sound)
    }

    func stop() {
        currentSound?.stop()
        currentSound = nil
    }

    private func play(_ sound: NSSound) {
        currentSound?.stop()
        currentSound = sound
        sound.play()
    }
}

@MainActor
final class SystemAgentActivitySoundPlayer: AgentActivitySoundPlaying {
    private let assetPlayer: any AgentActivitySoundAssetPlaying

    init(assetPlayer: any AgentActivitySoundAssetPlaying = AppAgentActivitySoundAssets()) {
        self.assetPlayer = assetPlayer
    }

    func play(_ sound: AgentActivitySound) {
        let configuration = switch sound {
        case .thinking:
            (name: "AgentThinking", fallback: "Pop", volume: Float(0.28))
        case .toolStarted:
            (name: "ToolStart", fallback: "Morse", volume: Float(0.42))
        case .toolCompleted:
            (name: "ToolComplete", fallback: "Tink", volume: Float(0.42))
        case .toolFailed:
            (name: "ToolFailed", fallback: "Basso", volume: Float(0.42))
        }
        if !assetPlayer.playBundled(named: configuration.name, volume: configuration.volume) {
            assetPlayer.playSystem(named: configuration.fallback)
        }
    }

    func stop() {
        assetPlayer.stop()
    }
}

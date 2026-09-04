// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import VoiceActivationCore

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
        return play(sound)
    }

    func playSystem(named name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        _ = play(sound)
    }

    func stop() {
        currentSound?.stop()
        currentSound = nil
    }

    private func play(_ sound: NSSound) -> Bool {
        currentSound?.stop()
        currentSound = sound
        guard sound.play() else {
            currentSound = nil
            return false
        }
        return true
    }
}

@MainActor
final class SystemAgentActivitySoundPlayer: AgentActivitySoundPlaying {
    private let assetPlayer: any AgentActivitySoundAssetPlaying
    private let diagnostics: any VoiceActivationDiagnosticRecording

    init(
        assetPlayer: any AgentActivitySoundAssetPlaying = AppAgentActivitySoundAssets(),
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.assetPlayer = assetPlayer
        self.diagnostics = diagnostics
    }

    func play(_ sound: AgentActivitySound) {
        let configuration =
            switch sound {
            case .thinking:
                (name: "AgentThinking", fallback: "Pop", volume: Float(0.70))
            case .toolStarted:
                (name: "ToolStart", fallback: "Morse", volume: Float(0.42))
            case .toolCompleted:
                (name: "ToolComplete", fallback: "Tink", volume: Float(0.42))
            case .toolFailed:
                (name: "ToolFailed", fallback: "Basso", volume: Float(0.42))
            }
        let bundledStarted = assetPlayer.playBundled(
            named: configuration.name,
            volume: configuration.volume)
        diagnostics.record(
            category: .audio,
            event: "activity.output_attempted",
            fields: [
                "sound": sound.outputDiagnosticName,
                "bundled_started": String(bundledStarted),
            ])
        if !bundledStarted {
            assetPlayer.playSystem(named: configuration.fallback)
            diagnostics.record(
                category: .audio,
                event: "activity.output_fallback_requested",
                level: .warning,
                fields: ["sound": sound.outputDiagnosticName])
        }
    }

    func stop() {
        assetPlayer.stop()
        diagnostics.record(category: .audio, event: "activity.output_stopped")
    }
}

extension AgentActivitySound {
    fileprivate var outputDiagnosticName: String {
        switch self {
        case .thinking: "thinking"
        case .toolStarted: "tool_started"
        case .toolCompleted: "tool_completed"
        case .toolFailed: "tool_failed"
        }
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import VoiceActivationCore

enum CaptureSoundEvent: Equatable {
    case started
    case ended
}

@MainActor
protocol CaptureSoundPlaying: AnyObject {
    func play(_ event: CaptureSoundEvent)
}

@MainActor
protocol CaptureSoundAssetPlaying: AnyObject {
    func playBundled(named name: String) -> Bool
    func playSystem(named name: String)
}

@MainActor
final class AppCaptureSoundAssets: CaptureSoundAssetPlaying {
    private var bundledSounds: [String: NSSound] = [:]

    func playBundled(named name: String) -> Bool {
        if let sound = bundledSounds[name] {
            return sound.play()
        }
        guard
            let url = Bundle.main.url(forResource: name, withExtension: "wav"),
            let sound = NSSound(contentsOf: url, byReference: true)
        else { return false }
        bundledSounds[name] = sound
        return sound.play()
    }

    func playSystem(named name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }
}

@MainActor
final class SystemCaptureSoundPlayer: CaptureSoundPlaying {
    private let assetPlayer: any CaptureSoundAssetPlaying
    private let diagnostics: any VoiceActivationDiagnosticRecording

    init(
        assetPlayer: any CaptureSoundAssetPlaying = AppCaptureSoundAssets(),
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.assetPlayer = assetPlayer
        self.diagnostics = diagnostics
    }

    func play(_ event: CaptureSoundEvent) {
        let names =
            switch event {
            case .started: (bundled: "CaptureStart", fallback: "Pop")
            case .ended: (bundled: "CaptureEnd", fallback: "Tink")
            }
        let bundledStarted = assetPlayer.playBundled(named: names.bundled)
        diagnostics.record(
            category: .audio,
            event: "capture_sound.output_attempted",
            fields: [
                "event": event == .started ? "started" : "ended",
                "bundled_started": String(bundledStarted),
            ])
        if !bundledStarted {
            assetPlayer.playSystem(named: names.fallback)
        }
    }
}

@MainActor
final class CaptureSoundPresenter {
    private let player: any CaptureSoundPlaying
    private var previousState: ActivationState = .disabled

    init(player: any CaptureSoundPlaying = SystemCaptureSoundPlayer()) {
        self.player = player
    }

    func update(state: ActivationState) {
        if previousState != .capturing, state == .capturing {
            VoiceActivationDiagnostics.shared.record(
                category: .audio,
                event: "capture_sound.transition_requested",
                fields: ["transition": "started"])
            player.play(.started)
        } else if previousState == .capturing, state != .capturing {
            VoiceActivationDiagnostics.shared.record(
                category: .audio,
                event: "capture_sound.transition_requested",
                fields: ["transition": "ended"])
            player.play(.ended)
        }
        previousState = state
    }
}

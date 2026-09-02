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
final class SystemCaptureSoundPlayer: CaptureSoundPlaying {
    func play(_ event: CaptureSoundEvent) {
        let name = switch event {
        case .started: "Pop"
        case .ended: "Tink"
        }
        NSSound(named: NSSound.Name(name))?.play()
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
            player.play(.started)
        } else if previousState == .capturing, state != .capturing {
            player.play(.ended)
        }
        previousState = state
    }
}

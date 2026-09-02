import AppKit
import VoiceActivationCore

@MainActor
enum WakeProfileAccentSwatch {
    static func image(for accent: WakeProfileAccent) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { bounds in
            accent.nsColor.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

private extension WakeProfileAccent {
    var nsColor: NSColor {
        switch self {
        case .cyan: .systemCyan
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .orange: .systemOrange
        case .green: .systemGreen
        }
    }
}

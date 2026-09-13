// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import YapOpsCore

/// The primitive macOS effect that carries out one system action.
///
/// Resolution is a pure mapping so the catalog can be tested without locking a
/// screen or muting a Mac. Only ``SystemActionEffectPerforming`` touches the
/// system, and only one implementation of it does anything.
enum SystemActionEffect: Equatable, Sendable {
    /// Posts a system-defined key from the `NX_KEYTYPE_*` set.
    case mediaKey(Int32)
    /// Posts a virtual key with modifier flags.
    case keyStroke(key: CGKeyCode, flags: CGEventFlags)
    /// Launches an application bundle by absolute path.
    case openApplication(path: String)
    /// Runs a system helper with explicit arguments and no shell.
    case helper(path: String, arguments: [String])

    /// System-defined key identifiers understood by the media subsystem.
    enum MediaKey {
        static let soundUp: Int32 = 0
        static let soundDown: Int32 = 1
        static let brightnessUp: Int32 = 2
        static let brightnessDown: Int32 = 3
        static let mute: Int32 = 7
        static let play: Int32 = 16
        static let next: Int32 = 17
        static let previous: Int32 = 18
    }

    /// Virtual key codes for the keyboard shortcuts macOS reserves.
    enum VirtualKey {
        static let q: CGKeyCode = 12
        static let f11: CGKeyCode = 103
        static let downArrow: CGKeyCode = 125
        static let upArrow: CGKeyCode = 126
    }

    /// Maps an action to the effect that performs it.
    ///
    /// - Parameter action: The requested operation.
    /// - Returns: The primitive effect to perform.
    static func resolve(_ action: SystemAction) -> SystemActionEffect {
        switch action {
        case .playPause: .mediaKey(MediaKey.play)
        case .nextTrack: .mediaKey(MediaKey.next)
        case .previousTrack: .mediaKey(MediaKey.previous)
        case .volumeUp: .mediaKey(MediaKey.soundUp)
        case .volumeDown: .mediaKey(MediaKey.soundDown)
        case .toggleMute: .mediaKey(MediaKey.mute)
        case .brightnessUp: .mediaKey(MediaKey.brightnessUp)
        case .brightnessDown: .mediaKey(MediaKey.brightnessDown)
        case .lockScreen:
            // The system shortcut for Lock Screen.
            .keyStroke(key: VirtualKey.q, flags: [.maskCommand, .maskControl])
        case .startScreenSaver:
            .openApplication(path: "/System/Library/CoreServices/ScreenSaverEngine.app")
        case .sleepDisplay:
            .helper(path: "/usr/bin/pmset", arguments: ["displaysleepnow"])
        case .sleepSystem:
            .helper(path: "/usr/bin/pmset", arguments: ["sleepnow"])
        case .missionControl:
            .keyStroke(key: VirtualKey.upArrow, flags: .maskControl)
        case .applicationWindows:
            .keyStroke(key: VirtualKey.downArrow, flags: .maskControl)
        case .showDesktop:
            .keyStroke(key: VirtualKey.f11, flags: [])
        }
    }
}

/// Carries out a resolved effect against the running system.
protocol SystemActionEffectPerforming: Sendable {
    /// Performs one primitive effect.
    ///
    /// - Parameter effect: The effect to carry out.
    /// - Throws: An error when the effect cannot be delivered.
    func perform(_ effect: SystemActionEffect) async throws
}

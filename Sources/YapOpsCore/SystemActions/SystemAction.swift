// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// A macOS system operation a wake profile can invoke by spoken term.
///
/// Raw values are persisted, so they are stable identifiers rather than display
/// text. An unknown raw value decodes to `nil` and its binding is dropped, which
/// lets a newer build add actions without corrupting an older build's profiles.
public enum SystemAction: String, CaseIterable, Codable, Equatable, Sendable {
    /// Toggles playback in the frontmost media application.
    case playPause
    /// Advances to the next track.
    case nextTrack
    /// Returns to the previous track.
    case previousTrack
    /// Raises the system output volume by one increment.
    case volumeUp
    /// Lowers the system output volume by one increment.
    case volumeDown
    /// Toggles system output mute.
    case toggleMute
    /// Raises display brightness by one increment.
    case brightnessUp
    /// Lowers display brightness by one increment.
    case brightnessDown
    /// Locks the screen immediately.
    case lockScreen
    /// Starts the configured screen saver.
    case startScreenSaver
    /// Puts the displays to sleep without sleeping the machine.
    case sleepDisplay
    /// Puts the machine to sleep.
    case sleepSystem
    /// Shows Mission Control.
    case missionControl
    /// Shows the frontmost application's windows.
    case applicationWindows
    /// Reveals the desktop.
    case showDesktop

    /// The grouping used to present actions for selection.
    public enum Category: String, CaseIterable, Codable, Equatable, Sendable {
        /// Playback transport.
        case media
        /// Output volume.
        case volume
        /// Display brightness.
        case display
        /// Screen locking, sleeping, and the screen saver.
        case session
        /// Window and desktop exposure.
        case windows

        /// The user-facing name of the category.
        public var title: String {
            switch self {
            case .media: "Media"
            case .volume: "Volume"
            case .display: "Display"
            case .session: "Session"
            case .windows: "Windows"
            }
        }

        /// The actions belonging to this category, in presentation order.
        public var actions: [SystemAction] {
            SystemAction.allCases.filter { $0.category == self }
        }
    }

    /// The grouping this action is presented under.
    public var category: Category {
        switch self {
        case .playPause, .nextTrack, .previousTrack: .media
        case .volumeUp, .volumeDown, .toggleMute: .volume
        case .brightnessUp, .brightnessDown: .display
        case .lockScreen, .startScreenSaver, .sleepDisplay, .sleepSystem: .session
        case .missionControl, .applicationWindows, .showDesktop: .windows
        }
    }

    /// The user-facing name of the action.
    public var title: String {
        switch self {
        case .playPause: "Play or pause"
        case .nextTrack: "Next track"
        case .previousTrack: "Previous track"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .toggleMute: "Mute or unmute"
        case .brightnessUp: "Brightness up"
        case .brightnessDown: "Brightness down"
        case .lockScreen: "Lock screen"
        case .startScreenSaver: "Start screen saver"
        case .sleepDisplay: "Sleep display"
        case .sleepSystem: "Sleep"
        case .missionControl: "Mission Control"
        case .applicationWindows: "Application windows"
        case .showDesktop: "Show desktop"
        }
    }

    /// The SF Symbol rendered beside the action.
    public var symbolName: String {
        switch self {
        case .playPause: "playpause.fill"
        case .nextTrack: "forward.end.fill"
        case .previousTrack: "backward.end.fill"
        case .volumeUp: "speaker.wave.3.fill"
        case .volumeDown: "speaker.wave.1.fill"
        case .toggleMute: "speaker.slash.fill"
        case .brightnessUp: "sun.max.fill"
        case .brightnessDown: "sun.min.fill"
        case .lockScreen: "lock.fill"
        case .startScreenSaver: "sparkles.tv.fill"
        case .sleepDisplay: "display"
        case .sleepSystem: "moon.zzz.fill"
        case .missionControl: "rectangle.3.group.fill"
        case .applicationWindows: "macwindow.on.rectangle"
        case .showDesktop: "menubar.dock.rectangle"
        }
    }

    /// The terms proposed when this action is first added to a profile.
    ///
    /// The first entry is the primary term; the rest are common alternatives a
    /// recognizer is likely to produce for the same intent.
    public var suggestedPhrases: [String] {
        switch self {
        case .playPause: ["play", "pause", "resume"]
        case .nextTrack: ["next", "skip", "next track"]
        case .previousTrack: ["previous", "back", "previous track"]
        case .volumeUp: ["volume up", "louder"]
        case .volumeDown: ["volume down", "quieter"]
        case .toggleMute: ["mute", "unmute"]
        case .brightnessUp: ["brighter", "brightness up"]
        case .brightnessDown: ["dimmer", "brightness down"]
        case .lockScreen: ["lock", "lock screen"]
        case .startScreenSaver: ["screen saver", "screensaver"]
        case .sleepDisplay: ["sleep display", "screen off"]
        case .sleepSystem: ["sleep", "go to sleep"]
        case .missionControl: ["mission control", "expose"]
        case .applicationWindows: ["app windows", "application windows"]
        case .showDesktop: ["show desktop", "desktop"]
        }
    }

    /// Whether performing this action requires the Accessibility permission.
    ///
    /// Actions that work by posting a synthetic key event need Accessibility.
    /// Those that launch a process or ask the workspace to act do not.
    public var requiresAccessibility: Bool {
        switch self {
        case .startScreenSaver, .sleepDisplay, .sleepSystem: false
        default: true
        }
    }

    /// The actions bound in a newly created system-action profile.
    ///
    /// Deliberately conservative: everyday transport and volume plus locking.
    /// Sleeping, brightness, and window exposure are available but opt-in,
    /// because a misrecognized term should not darken or suspend the machine.
    public static let defaultActions: [SystemAction] = [
        .playPause,
        .nextTrack,
        .previousTrack,
        .volumeUp,
        .volumeDown,
        .toggleMute,
        .lockScreen,
    ]
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import CoreGraphics
import Foundation

/// Failures raised while delivering an effect to macOS.
enum SystemActionEffectError: Error, LocalizedError {
    /// Core Graphics refused to build the event.
    case eventUnavailable
    /// The application bundle backing the effect is absent.
    case applicationMissing(String)
    /// The system helper is absent or not runnable.
    case helperMissing(String)
    /// The system helper exited with a nonzero status.
    case helperFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .eventUnavailable:
            "macOS refused to deliver the event."
        case let .applicationMissing(path):
            "\(path) is not installed."
        case let .helperMissing(path):
            "\(path) is missing or not runnable."
        case let .helperFailed(status):
            "The system helper exited with status \(status)."
        }
    }
}

/// Delivers system-action effects through AppKit, Core Graphics, and `pmset`.
struct AppKitSystemActionEffects: SystemActionEffectPerforming {
    /// Creates the production effect adapter.
    init() {}

    /// Performs one effect.
    ///
    /// - Parameter effect: The effect to carry out.
    /// - Throws: A ``SystemActionEffectError`` when macOS refuses the effect.
    func perform(_ effect: SystemActionEffect) async throws {
        switch effect {
        case let .mediaKey(keyCode):
            try await MainActor.run { try Self.postMediaKey(keyCode) }
        case let .keyStroke(key, flags):
            try await MainActor.run { try Self.postKeyStroke(key: key, flags: flags) }
        case let .openApplication(path):
            try await Self.openApplication(at: path)
        case let .helper(path, arguments):
            try await Self.runHelper(path: path, arguments: arguments)
        }
    }

    /// Posts a press and release of a system-defined media key.
    ///
    /// The media subsystem listens for `NSSystemDefined` subtype 8 events whose
    /// `data1` packs the key identifier and its up/down state, which is why this
    /// cannot use the ordinary keyboard event path.
    @MainActor
    private static func postMediaKey(_ keyCode: Int32) throws {
        for isDown in [true, false] {
            let state: Int32 = isDown ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((keyCode << 16) | (state << 8)),
                data2: -1)
            guard let cgEvent = event?.cgEvent else {
                throw SystemActionEffectError.eventUnavailable
            }
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    /// Posts a press and release of a virtual key with modifiers.
    @MainActor
    private static func postKeyStroke(key: CGKeyCode, flags: CGEventFlags) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else {
            throw SystemActionEffectError.eventUnavailable
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Launches a bundled application, such as the screen saver engine.
    private static func openApplication(at path: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw SystemActionEffectError.applicationMissing(path)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path),
            configuration: configuration)
    }

    /// Runs a system helper with an absolute path and explicit arguments.
    ///
    /// No shell is involved, matching the direct-command execution rule.
    private static func runHelper(path: String, arguments: [String]) async throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw SystemActionEffectError.helperMissing(path)
        }
        let status = try await Task.detached(priority: .userInitiated) { () -> Int32 in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        guard status == 0 else {
            throw SystemActionEffectError.helperFailed(status)
        }
    }
}

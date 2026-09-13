// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Testing
import YapOpsCore
@testable import YapOpsApp

struct SystemActionEffectTests {
    @Test func resolve_MapsEveryActionToADistinctEffect() {
        var seen: [(SystemAction, SystemActionEffect)] = []
        for action in SystemAction.allCases {
            let effect = SystemActionEffect.resolve(action)
            if let clash = seen.first(where: { $0.1 == effect }) {
                Issue.record("\(action) and \(clash.0) both resolve to \(effect)")
            }
            seen.append((action, effect))
        }
        #expect(seen.count == SystemAction.allCases.count)
    }

    @Test func resolve_UsesTheSystemLockShortcut() {
        #expect(SystemActionEffect.resolve(.lockScreen)
            == .keyStroke(key: 12, flags: [.maskCommand, .maskControl]))
    }

    @Test func resolve_UsesMediaKeysForTransportAndVolume() {
        #expect(SystemActionEffect.resolve(.playPause) == .mediaKey(16))
        #expect(SystemActionEffect.resolve(.nextTrack) == .mediaKey(17))
        #expect(SystemActionEffect.resolve(.previousTrack) == .mediaKey(18))
        #expect(SystemActionEffect.resolve(.volumeUp) == .mediaKey(0))
        #expect(SystemActionEffect.resolve(.volumeDown) == .mediaKey(1))
        #expect(SystemActionEffect.resolve(.toggleMute) == .mediaKey(7))
    }

    @Test func resolve_UsesAbsoluteHelperPathsWithExplicitArguments() {
        // No shell, matching the direct-command execution rule.
        #expect(SystemActionEffect.resolve(.sleepSystem)
            == .helper(path: "/usr/bin/pmset", arguments: ["sleepnow"]))
        #expect(SystemActionEffect.resolve(.sleepDisplay)
            == .helper(path: "/usr/bin/pmset", arguments: ["displaysleepnow"]))
    }

    @Test func resolve_KeyStrokeAndMediaEffectsAreExactlyTheAccessibilityActions() {
        // The grant requirement must track how the effect is delivered; a
        // synthesized event needs Accessibility and a launched process does not.
        for action in SystemAction.allCases {
            let needsEvent: Bool
            switch SystemActionEffect.resolve(action) {
            case .mediaKey, .keyStroke: needsEvent = true
            case .openApplication, .helper: needsEvent = false
            }
            #expect(
                action.requiresAccessibility == needsEvent,
                "\(action) declares the wrong Accessibility requirement")
        }
    }
}


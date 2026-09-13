// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import YapOpsCore

struct SystemActionCatalogTests {
    @Test func everyAction_HasUsableSuggestedPhrases() {
        for action in SystemAction.allCases {
            #expect(!action.suggestedPhrases.isEmpty, "\(action) suggests nothing")
            for phrase in action.suggestedPhrases {
                #expect(
                    WakePhraseMatcher.containsSpokenCharacter(phrase),
                    "\(action) suggests unspeakable \(phrase)")
            }
        }
    }

    @Test func everyAction_HasDistinctSuggestedPhrasesAcrossTheCatalog() {
        var owners: [String: SystemAction] = [:]
        for action in SystemAction.allCases {
            for phrase in action.suggestedPhrases {
                let canonical = WakePhraseMatcher.canonicalWakePhrase(phrase)
                #expect(
                    owners[canonical] == nil,
                    "\(phrase) is suggested by both \(action) and \(owners[canonical]!)")
                owners[canonical] = action
            }
        }
    }

    @Test func everyAction_HasTitleAndSymbol() {
        for action in SystemAction.allCases {
            #expect(!action.title.isEmpty)
            #expect(!action.symbolName.isEmpty)
        }
    }

    @Test func categories_PartitionEveryAction() {
        let grouped = SystemAction.Category.allCases.flatMap(\.actions)

        #expect(Set(grouped) == Set(SystemAction.allCases))
        #expect(grouped.count == SystemAction.allCases.count)
    }

    @Test func processBackedActions_DoNotRequireAccessibility() {
        // These run a helper or ask the workspace; only synthesized key events
        // need the Accessibility grant.
        #expect(SystemAction.sleepSystem.requiresAccessibility == false)
        #expect(SystemAction.sleepDisplay.requiresAccessibility == false)
        #expect(SystemAction.startScreenSaver.requiresAccessibility == false)
        #expect(SystemAction.playPause.requiresAccessibility)
        #expect(SystemAction.lockScreen.requiresAccessibility)
    }

    @Test func defaultActions_ExcludeTheDisruptiveOnes() {
        // A misrecognized term must not suspend or darken the machine.
        #expect(!SystemAction.defaultActions.contains(.sleepSystem))
        #expect(!SystemAction.defaultActions.contains(.sleepDisplay))
        #expect(SystemAction.defaultActions.contains(.playPause))
        #expect(SystemAction.defaultActions.contains(.lockScreen))
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import YapOpsCore

struct SystemActionSetTests {
    @Test func binding_NormalizesAndDeduplicatesPhrases() throws {
        let binding = try SystemActionBinding(
            action: .playPause,
            phrases: ["  Play  ", "play", "PLAY", " resume "])

        #expect(binding.phrases == ["Play", "resume"])
    }

    @Test func binding_DiscardsEmptyPhrasesInsteadOfFailing() throws {
        let binding = try SystemActionBinding(
            action: .nextTrack,
            phrases: ["next", "   ", ""])

        #expect(binding.phrases == ["next"])
    }

    @Test func binding_WhenNoPhraseSurvives_Throws() {
        #expect(throws: SystemActionBinding.ValidationError.phraseRequired) {
            try SystemActionBinding(action: .lockScreen, phrases: ["  ", "!!"])
        }
    }

    @Test func set_WhenEmpty_Throws() {
        #expect(throws: SystemActionSet.ValidationError.bindingRequired) {
            try SystemActionSet(bindings: [])
        }
    }

    @Test func set_WhenOnePhraseIsBoundTwice_Throws() throws {
        let play = try SystemActionBinding(action: .playPause, phrases: ["go"])
        let next = try SystemActionBinding(action: .nextTrack, phrases: ["Go"])

        #expect(throws: SystemActionSet.ValidationError.duplicatePhrase("Go")) {
            try SystemActionSet(bindings: [play, next])
        }
    }

    @Test func defaultValue_BindsEveryDefaultActionWithoutConflict() {
        #expect(SystemActionSet.defaultValue.actions == SystemAction.defaultActions)
    }

    @Test func coding_RoundTripsBindingsAndIdentity() throws {
        let original = SystemActionSet.defaultValue

        let decoded = try JSONDecoder().decode(
            SystemActionSet.self,
            from: JSONEncoder().encode(original))

        #expect(decoded == original)
        #expect(decoded.bindings.map(\.id) == original.bindings.map(\.id))
    }

    @Test func decoding_DropsABindingThisBuildCannotPerform() throws {
        // A profile written by a newer build names an action this build lacks.
        // The remaining bindings must stay usable.
        let json = """
        {"bindings":[
          {"id":"\(UUID().uuidString)","action":"teleport","phrases":["beam me up"]},
          {"id":"\(UUID().uuidString)","action":"playPause","phrases":["play"]}
        ]}
        """

        let decoded = try JSONDecoder().decode(
            SystemActionSet.self,
            from: Data(json.utf8))

        #expect(decoded.actions == [.playPause])
    }

    @Test func decoding_WhenNothingUsableRemains_Throws() {
        let json = """
        {"bindings":[{"id":"\(UUID().uuidString)","action":"teleport","phrases":["beam"]}]}
        """

        #expect(throws: SystemActionSet.ValidationError.bindingRequired) {
            try JSONDecoder().decode(SystemActionSet.self, from: Data(json.utf8))
        }
    }
}

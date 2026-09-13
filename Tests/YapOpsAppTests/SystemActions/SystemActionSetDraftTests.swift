// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import YapOpsCore
@testable import YapOpsApp

struct SystemActionSetDraftTests {
    @Test func termList_SplitsOnCommasAndTrims() {
        let row = SystemActionDraft(action: .playPause, terms: " play ,pause,  , resume")

        #expect(row.termList == ["play", "pause", "resume"])
    }

    @Test func draft_RoundTripsASavedSet() throws {
        let set = try SystemActionSet(bindings: [
            try SystemActionBinding(action: .lockScreen, phrases: ["lock", "lock screen"]),
        ])

        let rebuilt = try SystemActionSetDraft(set: set).validatedSet()

        #expect(rebuilt == set)
    }

    @Test func draft_PreservesRowIdentityAcrossAnEdit() throws {
        var draft = SystemActionSetDraft.defaultValue
        let id = draft.rows[0].id
        draft.rows[0].terms = "go, start"

        let set = try draft.validatedSet()

        #expect(set.bindings[0].id == id)
        #expect(set.bindings[0].phrases == ["go", "start"])
    }

    @Test func add_SeedsSuggestedTermsAndRefusesADuplicate() {
        var draft = SystemActionSetDraft(rows: [])

        draft.add(.sleepSystem)
        draft.add(.sleepSystem)

        #expect(draft.rows.count == 1)
        #expect(draft.rows[0].termList == SystemAction.sleepSystem.suggestedPhrases)
    }

    @Test func unboundActions_ExcludeWhatIsAlreadyBound() {
        var draft = SystemActionSetDraft(rows: [])
        draft.add(.playPause)

        #expect(!draft.unboundActions.contains(.playPause))
        #expect(draft.unboundActions.contains(.lockScreen))
        #expect(draft.unboundActions.count == SystemAction.allCases.count - 1)
    }

    @Test func remove_DropsOnlyThatRow() {
        var draft = SystemActionSetDraft.defaultValue
        let removed = draft.rows[1]

        draft.remove(removed.id)

        #expect(!draft.rows.contains { $0.id == removed.id })
        #expect(draft.rows.count == SystemActionSetDraft.defaultValue.rows.count - 1)
    }

    @Test func validatedSet_WhenARowHasNoTerms_Throws() {
        let draft = SystemActionSetDraft(rows: [
            SystemActionDraft(action: .playPause, terms: "  , "),
        ])

        #expect(throws: SystemActionBinding.ValidationError.phraseRequired) {
            try draft.validatedSet()
        }
    }

    @Test func validatedSet_WhenTwoRowsShareATerm_Throws() {
        let draft = SystemActionSetDraft(rows: [
            SystemActionDraft(action: .playPause, terms: "go"),
            SystemActionDraft(action: .nextTrack, terms: "go"),
        ])

        #expect(throws: SystemActionSet.ValidationError.duplicatePhrase("go")) {
            try draft.validatedSet()
        }
    }
}

@MainActor
struct WakeProfileDraftSystemActionTests {
    @Test func profileDraft_RoundTripsASystemActionProfile() throws {
        let profile = try WakeProfile(
            name: "Mac",
            wakePhrase: "mac",
            action: .systemAction(try SystemActionSet(bindings: [
                try SystemActionBinding(action: .playPause, phrases: ["play"]),
            ])),
            accent: .green)

        let rebuilt = try WakeProfileDraft(profile: profile).validatedProfile()

        #expect(rebuilt == profile)
    }

    @Test func profileDraft_WhenLoadedFromSystemAction_SelectsThatTarget() throws {
        let profile = try WakeProfile(
            wakePhrase: "mac",
            action: .systemAction(.defaultValue),
            accent: .green)

        #expect(WakeProfileDraft(profile: profile).targetKind == .systemAction)
    }

    @Test func selectTarget_ToSystemAction_PreservesTheUnsavedCommand() throws {
        var draft = WakeProfileDraft(
            wakePhrase: "mac",
            urlTemplate: "https://example.com?q={urlText}",
            accent: .green)
        draft.executablePath = "/usr/bin/true"

        draft.selectTarget(.systemAction)

        #expect(draft.targetKind == .systemAction)
        #expect(draft.executablePath == "/usr/bin/true")
    }

    @Test func validatedProfile_WhenTargetIsSystemAction_IgnoresTheCommandBranch() throws {
        var draft = WakeProfileDraft(
            wakePhrase: "mac",
            urlTemplate: "no placeholder here",
            accent: .green)
        draft.selectTarget(.systemAction)

        let profile = try draft.validatedProfile()

        guard case let .systemAction(set) = profile.action else {
            Issue.record("expected a system-action profile")
            return
        }
        #expect(set.actions == SystemAction.defaultActions)
    }
}

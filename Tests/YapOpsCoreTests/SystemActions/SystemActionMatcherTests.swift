// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import YapOpsCore

struct SystemActionMatcherTests {
    private func makeSet() throws -> SystemActionSet {
        try SystemActionSet(bindings: [
            try SystemActionBinding(action: .playPause, phrases: ["play", "pause"]),
            try SystemActionBinding(action: .nextTrack, phrases: ["next", "next track"]),
            try SystemActionBinding(action: .lockScreen, phrases: ["lock"]),
        ])
    }

    @Test func resolve_WhenTermIsCompleteAndUnambiguous_MatchesImmediately() throws {
        let set = try makeSet()

        let resolution = SystemActionMatcher.resolve("lock", in: set, isComplete: false)

        guard case let .matched(match) = resolution else {
            Issue.record("expected a match, got \(resolution)")
            return
        }
        #expect(match.action == .lockScreen)
        #expect(match.phrase == "lock")
    }

    @Test func resolve_WhenALongerTermCouldStillArrive_WaitsForMoreSpeech() throws {
        let set = try makeSet()

        // "next" is bound, but so is "next track"; acting now would skip a track
        // the moment someone says the longer term.
        #expect(SystemActionMatcher.resolve("next", in: set, isComplete: false) == .pending)
    }

    @Test func resolve_WhenTheUtteranceEnds_SettlesTheShorterTerm() throws {
        let set = try makeSet()

        let resolution = SystemActionMatcher.resolve("next", in: set, isComplete: true)

        guard case let .matched(match) = resolution else {
            Issue.record("expected a match, got \(resolution)")
            return
        }
        #expect(match.action == .nextTrack)
        #expect(match.phrase == "next")
    }

    @Test func resolve_WhenTheLongerTermArrives_MatchesIt() throws {
        let set = try makeSet()

        let resolution = SystemActionMatcher.resolve("next track", in: set, isComplete: false)

        guard case let .matched(match) = resolution else {
            Issue.record("expected a match, got \(resolution)")
            return
        }
        #expect(match.action == .nextTrack)
        #expect(match.phrase == "next track")
    }

    @Test func resolve_WhenTextIsAPartialTerm_WaitsRatherThanFailing() throws {
        let set = try makeSet()

        #expect(SystemActionMatcher.resolve("loc", in: set, isComplete: false) == .pending)
    }

    @Test func resolve_WhenAPartialTermNeverCompletes_IsUnmatched() throws {
        let set = try makeSet()

        #expect(SystemActionMatcher.resolve("loc", in: set, isComplete: true) == .unmatched)
    }

    @Test func resolve_WhenNothingIsSaidYet_WaitsForTheTerm() throws {
        let set = try makeSet()

        #expect(SystemActionMatcher.resolve("", in: set, isComplete: false) == .pending)
        #expect(SystemActionMatcher.resolve("", in: set, isComplete: true) == .unmatched)
    }

    @Test func resolve_IgnoresCaseDiacriticsAndTrailingPunctuation() throws {
        let set = try makeSet()

        for spoken in ["Play", "PLAY!", " play. ", "pláy"] {
            guard case let .matched(match) = SystemActionMatcher.resolve(
                spoken,
                in: set,
                isComplete: true)
            else {
                Issue.record("\(spoken) did not match")
                return
            }
            #expect(match.action == .playPause)
        }
    }

    @Test func resolve_WhenTermIsNotBound_IsUnmatched() throws {
        let set = try makeSet()

        #expect(SystemActionMatcher.resolve("order a pizza", in: set, isComplete: true)
            == .unmatched)
        #expect(SystemActionMatcher.resolve("order a pizza", in: set, isComplete: false)
            == .unmatched)
    }

    @Test func resolve_WhenTermHasTrailingWords_DoesNotMatchThePrefix() throws {
        let set = try makeSet()

        // "play the beatles" is a request, not the bound term "play".
        #expect(SystemActionMatcher.resolve("play the beatles", in: set, isComplete: true)
            == .unmatched)
    }

    @Test func match_ReturnsTheBindingIdentity() throws {
        let set = try makeSet()
        let expectedID = set.bindings[2].id

        let match = SystemActionMatcher.match("lock", in: set)

        #expect(match?.bindingID == expectedID)
        #expect(match?.action == .lockScreen)
    }

    @Test func match_WhenUnbound_ReturnsNil() throws {
        #expect(SystemActionMatcher.match("fly", in: try makeSet()) == nil)
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import YapOpsCore
@testable import YapOpsApp

@MainActor
struct MacSystemActionPerformerTests {
    @Test func perform_WhenAccessibilityIsMissing_RefusesASynthesizedAction() async throws {
        let effects = RecordingEffects()
        let performer = MacSystemActionPerformer(
            accessibility: MacContextAccessNativeSpy(isTrusted: false),
            effects: effects)

        await #expect(throws: SystemActionError.accessibilityNotGranted(.playPause)) {
            try await performer.perform(.playPause)
        }
        #expect(await effects.recorded().isEmpty)
    }

    @Test func perform_WhenAccessibilityIsMissing_StillRunsAProcessBackedAction() async throws {
        // Sleeping the display launches a helper and needs no synthesized event,
        // so a missing Accessibility grant must not block it.
        let effects = RecordingEffects()
        let performer = MacSystemActionPerformer(
            accessibility: MacContextAccessNativeSpy(isTrusted: false),
            effects: effects)

        try await performer.perform(.sleepDisplay)

        #expect(await effects.recorded() == [SystemActionEffect.resolve(.sleepDisplay)])
    }

    @Test func perform_WhenTrusted_DeliversTheResolvedEffect() async throws {
        let effects = RecordingEffects()
        let performer = MacSystemActionPerformer(
            accessibility: MacContextAccessNativeSpy(isTrusted: true),
            effects: effects)

        try await performer.perform(.lockScreen)

        #expect(await effects.recorded() == [SystemActionEffect.resolve(.lockScreen)])
    }

    @Test func perform_WhenTheEffectFails_ReportsTheOwningAction() async throws {
        let effects = RecordingEffects(failure: SystemActionEffectError.eventUnavailable)
        let performer = MacSystemActionPerformer(
            accessibility: MacContextAccessNativeSpy(isTrusted: true),
            effects: effects)

        await #expect(throws: SystemActionError.self) {
            try await performer.perform(.nextTrack)
        }
        do {
            try await performer.perform(.nextTrack)
        } catch let error as SystemActionError {
            guard case let .failed(action, _) = error else {
                Issue.record("expected a failure, got \(error)")
                return
            }
            #expect(action == .nextTrack)
        }
    }
}

/// Records delivered effects without touching macOS.
actor RecordingEffects: SystemActionEffectPerforming {
    private var effects: [SystemActionEffect] = []
    private let failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    func perform(_ effect: SystemActionEffect) async throws {
        if let failure { throw failure }
        effects.append(effect)
    }

    func recorded() -> [SystemActionEffect] {
        effects
    }
}

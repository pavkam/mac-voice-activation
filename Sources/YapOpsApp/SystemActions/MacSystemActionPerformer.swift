// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import YapOpsCore

/// Performs a wake profile's macOS action, refusing when its grant is missing.
struct MacSystemActionPerformer: SystemActionPerforming {
    private let accessibility: any MacContextAccessNativeChecking
    private let effects: any SystemActionEffectPerforming

    /// Creates a performer over a trust check and an effect adapter.
    ///
    /// - Parameters:
    ///   - accessibility: Reports whether this process may synthesize input.
    ///   - effects: Carries resolved effects to the system.
    init(
        accessibility: any MacContextAccessNativeChecking = SystemMacContextAccessNativeChecker(),
        effects: any SystemActionEffectPerforming = AppKitSystemActionEffects()
    ) {
        self.accessibility = accessibility
        self.effects = effects
    }

    /// Performs one action.
    ///
    /// Actions that synthesize input are checked against the Accessibility
    /// grant first, so a missing permission reports itself instead of failing
    /// silently the way a dropped `CGEvent` does.
    ///
    /// - Parameter action: The macOS operation to perform.
    /// - Throws: A ``SystemActionError`` describing the refusal or failure.
    func perform(_ action: SystemAction) async throws {
        if action.requiresAccessibility {
            let accessibility = accessibility
            let isTrusted = await MainActor.run { accessibility.isProcessTrusted() }
            guard isTrusted else {
                throw SystemActionError.accessibilityNotGranted(action)
            }
        }
        do {
            try await effects.perform(SystemActionEffect.resolve(action))
        } catch let error as SystemActionError {
            throw error
        } catch {
            throw SystemActionError.failed(action, error.localizedDescription)
        }
    }
}

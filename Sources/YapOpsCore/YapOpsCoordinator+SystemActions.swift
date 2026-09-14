// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

extension YapOpsCoordinator {
    /// Resolves the spoken term and performs its bound macOS action.
    ///
    /// A term that resolves to nothing fails the run with a spoken-term message
    /// rather than silently returning to listening, so a misheard word is
    /// visible instead of looking like the profile did not trigger.
    func startSystemAction(
        set: SystemActionSet,
        transcript: String,
        profile: WakeProfile,
        generation: Int
    ) {
        guard let match = SystemActionMatcher.match(transcript, in: set) else {
            diagnostics.record(
                category: .systemAction,
                event: "coordinator.system_action_unmatched",
                level: .warning,
                fields: [
                    "generation": String(generation),
                    "profile_id": profile.id.uuidString,
                    "bound_action_count": String(set.bindings.count),
                    "character_count": String(transcript.count),
                ])
            executionTask = nil
            executingAction = nil
            state = .failed(CoordinatorError.systemActionNotRecognized(transcript)
                .localizedDescription)
            resumePassiveAfterCooldown()
            return
        }

        let action = match.action
        diagnostics.record(
            category: .systemAction,
            event: "coordinator.system_action_started",
            fields: [
                "generation": String(generation),
                "profile_id": profile.id.uuidString,
                "system_action": action.rawValue,
            ])

        let mainRunLoopScheduler = MainRunLoopScheduler.shared
        executionTask = Task.detached(priority: .userInitiated) {
            [weak self, systemActionPerformer] in
            do {
                try Task.checkCancellation()
                try await systemActionPerformer.perform(action)
                mainRunLoopScheduler.schedule { [weak self] in
                    self?.finishSystemAction(action, generation: generation)
                }
            } catch is CancellationError {
                return
            } catch {
                mainRunLoopScheduler.schedule { [weak self] in
                    self?.failSystemAction(error, action: action, generation: generation)
                }
            }
        }
    }

    func finishSystemAction(_ action: SystemAction, generation: Int) {
        guard executionGeneration == generation else { return }
        diagnostics.record(
            category: .systemAction,
            event: "coordinator.system_action_finished",
            fields: [
                "generation": String(generation),
                "system_action": action.rawValue,
            ])
        executionTask = nil
        executingAction = nil
        onActionFeedback?(.systemActionSucceeded(action))
        resumePassiveAfterCooldown()
    }

    func failSystemAction(_ error: any Error, action: SystemAction, generation: Int) {
        guard executionGeneration == generation else { return }
        diagnostics.record(
            category: .systemAction,
            event: "coordinator.system_action_failed",
            level: .error,
            fields: [
                "generation": String(generation),
                "system_action": action.rawValue,
                "error_type": String(describing: type(of: error)),
            ])
        executionTask = nil
        executingAction = nil
        state = .failed(error.localizedDescription)
        onActionFeedback?(.systemActionFailed(action, reason: error.localizedDescription))
        resumePassiveAfterCooldown()
    }
}

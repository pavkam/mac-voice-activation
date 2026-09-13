// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import YapOpsCore

extension AppModel {
    /// Cancels the active recording overlay without invoking its profile action.
    func cancelCapture() {
        diagnostics.record(category: .ui, event: "app_model.capture_cancel_clicked")
        heldHotKeyProfileID = nil
        coordinator.cancelCapture()
    }

    /// Restores or fronts the retained agent conversation panel.
    func showAgentRun() {
        guard let runID = agentRunSnapshot?.runID else {
            diagnostics.record(
                category: .ui,
                event: "app_model.agent_run_open_ignored",
                fields: ["reason": "no_snapshot"])
            return
        }
        diagnostics.record(
            category: .ui,
            event: "app_model.agent_run_open_clicked",
            fields: ["run_id": runID.uuidString])
        agentRunPanelPresenter.show(runID: runID)
    }

    /// Removes a terminal conversation from both panel and retained presentation state.
    func deleteAgentRun() {
        guard let snapshot = agentRunSnapshot, snapshot.phase.isTerminal else {
            diagnostics.record(
                category: .ui,
                event: "app_model.agent_run_delete_ignored",
                fields: ["reason": "no_terminal_snapshot"])
            return
        }
        diagnostics.record(
            category: .ui,
            event: "app_model.agent_run_delete_clicked",
            fields: ["run_id": snapshot.runID.uuidString])
        agentRunPanelPresenter.delete(runID: snapshot.runID)
    }

    /// Begins cancellation of the active turn and immediately reflects it in presentation state.
    func cancelAgentRun(runID: UUID) {
        diagnostics.record(
            category: .ui,
            event: "app_model.stop_turn_clicked",
            fields: ["run_id": runID.uuidString])
        guard agentRunPresentation.beginCancellation(runID: runID) else {
            diagnostics.record(
                category: .ui,
                event: "app_model.stop_turn_ignored",
                fields: ["run_id": runID.uuidString])
            return
        }
        coordinator.cancelAgentRun()
    }

    func resumeAgentConversationListening(runID: UUID) {
        guard agentRunSnapshot?.runID == runID, agentRunSnapshot?.phase == .paused,
            coordinator.resumeAgentConversationListening() else { return }
        agentRunPresentation.resumeListening(runID: runID)
    }

    /// Ends the complete conversation while rejecting stale panel actions by run identity.
    /// Sends a typed follow-up, or resends a failed request.
    ///
    /// The coordinator owns every constraint that matters here — an active
    /// conversation, the prompt byte ceiling, and the pending-prompt bound — so
    /// this only establishes that the request belongs to the run on screen.
    func submitAgentFollowUp(runID: UUID, text: String) {
        guard agentRunSnapshot?.runID == runID else {
            diagnostics.record(
                category: .ui,
                event: "app_model.follow_up_ignored",
                fields: [
                    "run_id": runID.uuidString,
                    "reason": "stale_run",
                ])
            return
        }
        diagnostics.record(
            category: .ui,
            event: "app_model.follow_up_submitted",
            fields: [
                "run_id": runID.uuidString,
                "character_count": String(text.count),
            ])
        coordinator.submitAgentFollowUp(text)
    }

    func endAgentConversation(runID: UUID) {
        guard agentRunSnapshot?.runID == runID,
            agentRunSnapshot?.phase.isTerminal == false
        else {
            diagnostics.record(
                category: .ui,
                event: "app_model.end_conversation_ignored",
                fields: ["run_id": runID.uuidString])
            return
        }
        diagnostics.record(
            category: .ui,
            event: "app_model.end_conversation_clicked",
            fields: ["run_id": runID.uuidString])
        coordinator.endAgentConversation()
    }

    /// Sends a clicked permission choice for the currently presented turn.
    func resolveAgentPermission(
        runID: UUID,
        key: AgentPermissionKey,
        optionID: String
    ) {
        resolveAgentPermission(runID: runID, key: key, selectedOptionID: optionID)
    }

    func resolveAgentPermission(
        runID: UUID,
        key: AgentPermissionKey,
        selectedOptionID: String?
    ) {
        diagnostics.record(
            category: .ui,
            event: "app_model.permission_selected",
            fields: [
                "run_id": runID.uuidString,
                "has_option": String(selectedOptionID != nil),
            ])
        guard agentRunPresentation.beginPermissionResolution(runID: runID, key: key) else {
            diagnostics.record(
                category: .ui,
                event: "app_model.permission_ignored",
                fields: ["run_id": runID.uuidString])
            return
        }
        agentConversationAudioPresenter.permissionResolutionBegan(
            runID: runID,
            turnToken: key.turnToken,
            requestID: key.requestID)
        coordinator.resolveAgentPermission(
            runID: runID,
            turnToken: key.turnToken,
            requestID: key.requestID,
            optionID: selectedOptionID)
    }

    /// Handles spoken permission choices before ordinary follow-up submission.
    ///
    /// - Returns: Whether the utterance was consumed as a presentation-level command.
    func handleAgentVoiceUtterance(_ utterance: String) -> Bool {
        diagnostics.record(
            category: .speechRecognition,
            event: "app_model.agent_voice_utterance_received",
            fields: ["character_count": String(utterance.count)])
        guard let snapshot = agentRunSnapshot,
            !snapshot.phase.isTerminal,
            let permission = snapshot.permissions.first,
            let decision = AgentPermissionVoiceCommand.match(
                utterance,
                options: permission.options)
        else {
            diagnostics.record(
                category: .speechRecognition,
                event: "app_model.agent_voice_utterance_not_handled",
                fields: ["reason": "not_permission_command"])
            return false
        }

        switch decision {
        case .select(let optionID):
            diagnostics.record(
                category: .speechRecognition,
                event: "app_model.permission_voice_command_matched",
                fields: [
                    "run_id": snapshot.runID.uuidString,
                    "decision": "select",
                ])
            resolveAgentPermission(
                runID: snapshot.runID,
                key: permission.key,
                selectedOptionID: optionID)
        case .cancel:
            diagnostics.record(
                category: .speechRecognition,
                event: "app_model.permission_voice_command_matched",
                fields: [
                    "run_id": snapshot.runID.uuidString,
                    "decision": "cancel",
                ])
            resolveAgentPermission(
                runID: snapshot.runID,
                key: permission.key,
                selectedOptionID: nil)
        }
        return true
    }

    /// Routes ordered coordinator lifecycle events into presentation and audio pipelines.
    func handleAgentRunLifecycleEvent(_ event: AgentRunLifecycleEvent) {
        agentLifecycleSequence &+= 1
        diagnostics.record(
            category: .agent,
            event: "app_model.lifecycle_received",
            fields: event.appModelDiagnosticFields.merging([
                "lifecycle_sequence": String(agentLifecycleSequence),
                "task_priority": String(Task.currentPriority.rawValue),
            ]) { _, new in new })
        switch event {
        case .dismissedBySpeech(let runID):
            pendingSpeechDismissalRunID = runID
        case .started(let runID, let profile, let prompt):
            // A prior conversation's dismissal cannot still be pending once a
            // new one begins under the same runID space.
            pendingSpeechDismissalRunID = nil
            prepareAgentPresentation(runID: runID, profile: profile)
            agentRunPresentation.start(runID: runID, profile: profile, prompt: prompt)
            if interruptedAgentWork.contains(where: {
                $0.key.profileID == profile.id && $0.providerTaskID != nil
            }) {
                agentRunPresentation.receiveNotice(
                    runID: runID,
                    message: "Interrupted when YapOps exited")
            }
        case .followUpSubmitted(let runID, let inputID, let prompt, let disposition):
            agentRunPresentation.submitFollowUp(
                runID: runID,
                inputID: inputID,
                prompt: prompt,
                disposition: disposition)
        case .followUpDispositionChanged(let runID, let inputID, let disposition):
            agentRunPresentation.updateFollowUp(
                runID: runID,
                inputID: inputID,
                disposition: disposition)
        case .inputContextCaptured(let runID, let inputID, let summary):
            agentRunPresentation.receiveContext(runID: runID, inputID: inputID, summary: summary)
        case .notice(let runID, let message):
            agentRunPresentation.receiveNotice(runID: runID, message: message)
        case .turnStarted(let runID):
            agentRunPresentation.beginTurn(runID: runID)
        case .turnCancellationStarted(let runID):
            _ = agentRunPresentation.beginCancellation(runID: runID)
        case .event(let runID, let event):
            agentRunPresentation.receive(runID: runID, event: event)
            if case .connected(_, let sessionID) = event {
                registerAgentSession(runID: runID, sessionID: sessionID)
            }
        case .historyRestorationStarted(let runID, let token, let sessionID):
            agentRunPresentation.beginHistoryRestoration(
                runID: runID,
                token: token,
                sessionID: sessionID)
        case .historyEvent(let runID, let token, let event):
            agentRunPresentation.receiveRestored(
                runID: runID,
                token: token,
                event: event)
        case .historyRestorationCompleted(let runID, let token, let activation):
            agentRunPresentation.completeHistoryRestoration(
                runID: runID,
                token: token,
                activation: activation)
        case .historyRestorationAborted(let runID, let token):
            agentRunPresentation.abortHistoryRestoration(
                runID: runID,
                token: token)
        case .turnCompleted(let runID, let result):
            agentRunPresentation.completeTurn(runID: runID, result: result)
        case .turnFailed(let runID, let message):
            agentRunPresentation.interruptTurn(runID: runID, message: message)
        case .completed(let runID, let result):
            agentRunPresentation.complete(runID: runID, result: result)
            if pendingSpeechDismissalRunID == runID {
                pendingSpeechDismissalRunID = nil
                agentRunPanelPresenter.hide(runID: runID)
            }
        case .failed(let runID, let message):
            agentRunPresentation.fail(runID: runID, message: message)
        }
        agentConversationAudioPresenter.handle(event)
        diagnostics.record(
            category: .agent,
            event: "app_model.lifecycle_dispatched",
            fields: [
                "lifecycle_sequence": String(agentLifecycleSequence),
                "task_priority": String(Task.currentPriority.rawValue),
            ])
    }

}

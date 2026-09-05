// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

extension VoiceActivationCoordinator {
    func execute(_ transcript: String) {
        guard let action = capturedAction, let profile = activeProfile else {
            diagnostics.record(
                category: .app,
                event: "coordinator.execution_rejected",
                level: .error,
                fields: ["reason": "action_unavailable"])
            state = .failed(CoordinatorError.actionUnavailable.localizedDescription)
            resumePassiveAfterCooldown()
            return
        }

        executionGeneration &+= 1
        let activeExecutionGeneration = executionGeneration
        let pendingAgentCancellation = agentCancellationTask
        executionTask?.cancel()
        state = .executing
        lastTranscript = transcript
        diagnostics.record(
            category: .app,
            event: "coordinator.execution_queued",
            fields: [
                "generation": String(activeExecutionGeneration),
                "profile_id": profile.id.uuidString,
                "action": action.coordinatorDiagnosticName,
                "character_count": String(transcript.count),
                "waits_for_cancellation": String(pendingAgentCancellation != nil),
            ])

        guard let pendingAgentCancellation else {
            startExecution(
                action: action,
                profile: profile,
                transcript: transcript,
                generation: activeExecutionGeneration)
            return
        }

        let mainRunLoopScheduler = MainRunLoopScheduler.shared
        executionTask = Task.detached(priority: .userInitiated) { [weak self] in
            await pendingAgentCancellation.value
            guard !Task.isCancelled else { return }
            mainRunLoopScheduler.schedule { [weak self] in
                guard
                    let self,
                    self.executionGeneration == activeExecutionGeneration
                else { return }
                self.startExecution(
                    action: action,
                    profile: profile,
                    transcript: transcript,
                    generation: activeExecutionGeneration)
            }
        }
    }

    func startExecution(
        action: WakeProfileAction,
        profile: WakeProfile,
        transcript: String,
        generation: Int
    ) {
        guard executionGeneration == generation else { return }
        executingAction = action
        diagnostics.record(
            category: .app,
            event: "coordinator.execution_started",
            fields: [
                "generation": String(generation),
                "profile_id": profile.id.uuidString,
                "action": action.coordinatorDiagnosticName,
            ])

        switch action {
        case .command(let template):
            activeAgentRunID = nil
            let mainRunLoopScheduler = MainRunLoopScheduler.shared
            executionTask = Task.detached(priority: .userInitiated) {
                [weak self, commandRunner] in
                do {
                    try Task.checkCancellation()
                    _ = try await commandRunner.run(template: template, transcript: transcript)
                    mainRunLoopScheduler.schedule { [weak self] in
                        self?.finishCommandExecution(generation: generation)
                    }
                } catch {
                    mainRunLoopScheduler.schedule { [weak self] in
                        self?.failCommandExecution(error, generation: generation)
                    }
                }
            }
        case .agent(let agentConfiguration):
            let runID = UUID()
            diagnostics.record(
                category: .agent,
                event: "coordinator.agent_conversation_started",
                fields: [
                    "run_id": runID.uuidString,
                    "profile_id": profile.id.uuidString,
                    "generation": String(generation),
                    "input_character_count": String(transcript.count),
                ])
            activeAgentRunID = runID
            pendingAgentPrompts.removeAll()
            agentConversationEndResult = nil
            onAgentRunEvent?(
                .started(
                    runID: runID,
                    profile: profile,
                    prompt: transcript))
            startAgentTurn(
                prompt: transcript,
                profile: profile,
                configuration: agentConfiguration,
                runID: runID,
                generation: generation)
            startConversationListening()
        }
    }

    func submitAgentFollowUp(_ prompt: String) {
        guard case .agent = executingAction, let runID = activeAgentRunID else {
            diagnostics.record(
                category: .agent,
                event: "coordinator.follow_up_ignored",
                fields: ["reason": "no_active_conversation"])
            return
        }
        guard pendingAgentPrompts.count < Self.maximumPendingAgentPrompts else {
            diagnostics.record(
                category: .agent,
                event: "coordinator.follow_up_rejected",
                level: .warning,
                fields: [
                    "run_id": runID.uuidString,
                    "reason": "queue_full",
                    "pending_count": String(pendingAgentPrompts.count),
                ])
            onAgentRunEvent?(
                .notice(
                    runID: runID,
                    message: "Follow-up queue is full. Wait for the agent before speaking again."))
            return
        }
        pendingAgentPrompts.append(prompt)
        diagnostics.record(
            category: .agent,
            event: "coordinator.follow_up_queued",
            fields: [
                "run_id": runID.uuidString,
                "character_count": String(prompt.count),
                "pending_count": String(pendingAgentPrompts.count),
                "turn_active": String(executionTask != nil),
            ])
        onAgentRunEvent?(.followUpSubmitted(runID: runID, prompt: prompt))

        guard agentCancellationTask == nil else { return }
        guard executionTask == nil else {
            onAgentRunEvent?(.turnCancellationStarted(runID: runID))
            executionGeneration &+= 1
            executionTask?.cancel()
            executionTask = nil
            beginAgentCancellation(runID: runID)
            return
        }
        startNextAgentPrompt()
    }

    func startNextAgentPrompt() {
        guard
            agentCancellationTask == nil,
            executionTask == nil,
            !pendingAgentPrompts.isEmpty,
            case .agent(let configuration) = executingAction,
            let profile = activeProfile,
            let runID = activeAgentRunID
        else { return }

        let prompt = pendingAgentPrompts.removeFirst()
        executionGeneration &+= 1
        let generation = executionGeneration
        onAgentRunEvent?(.turnStarted(runID: runID))
        state = .executing
        diagnostics.record(
            category: .agent,
            event: "coordinator.follow_up_started",
            fields: [
                "run_id": runID.uuidString,
                "generation": String(generation),
                "character_count": String(prompt.count),
                "remaining_pending_count": String(pendingAgentPrompts.count),
            ])
        startAgentTurn(
            prompt: prompt,
            profile: profile,
            configuration: configuration,
            runID: runID,
            generation: generation)
    }

    func startAgentTurn(
        prompt: String,
        profile: WakeProfile,
        configuration: AgentHarnessConfiguration,
        runID: UUID,
        generation: Int
    ) {
        agentTurnHadActivity = false
        let scheduledAtUptime = DispatchTime.now().uptimeNanoseconds
        diagnostics.record(
            category: .agent,
            event: "coordinator.agent_turn_started",
            fields: [
                "run_id": runID.uuidString,
                "generation": String(generation),
                "input_character_count": String(prompt.count),
                "task_priority": String(Task.currentPriority.rawValue),
            ])
        let diagnostics = diagnostics
        let launchCancellationGrace = Self.agentLaunchCancellationGrace
        let mainRunLoopScheduler = MainRunLoopScheduler.shared
        executionTask = Task.detached(priority: .userInitiated) { [weak self, agentRunner] in
            let startedAtUptime = DispatchTime.now().uptimeNanoseconds
            let schedulingDelay = startedAtUptime >= scheduledAtUptime
                ? (startedAtUptime - scheduledAtUptime) / 1_000_000
                : 0
            diagnostics.record(
                category: .agent,
                event: "coordinator.agent_execution_task_started",
                fields: [
                    "run_id": runID.uuidString,
                    "generation": String(generation),
                    "scheduling_delay_ms": String(schedulingDelay),
                    "task_priority": String(Task.currentPriority.rawValue),
                ])
            do {
                // Preserve a brief cancellation window for stop actions issued in the
                // same input turn while still overlapping ACP startup with the much
                // slower synchronous conversation-recognition setup.
                try await Task.sleep(for: launchCancellationGrace)
                try Task.checkCancellation()
                let readyAtUptime = DispatchTime.now().uptimeNanoseconds
                let launchDelay = readyAtUptime >= scheduledAtUptime
                    ? (readyAtUptime - scheduledAtUptime) / 1_000_000
                    : 0
                diagnostics.record(
                    category: .agent,
                    event: "coordinator.agent_execution_task_ready",
                    fields: [
                        "run_id": runID.uuidString,
                        "generation": String(generation),
                        "launch_delay_ms": String(launchDelay),
                        "task_priority": String(Task.currentPriority.rawValue),
                    ])
                let result = try await agentRunner.run(
                    profileID: profile.id,
                    configuration: configuration,
                    prompt: prompt,
                    onEvent: { [weak self] event in
                        let receivedAtUptime = DispatchTime.now().uptimeNanoseconds
                        await mainRunLoopScheduler.perform { [weak self] in
                            self?.publishAgentEvent(
                                event,
                                runID: runID,
                                generation: generation,
                                receivedAtUptime: receivedAtUptime)
                        }
                    })
                await mainRunLoopScheduler.perform { [weak self] in
                    self?.finishAgentExecution(
                        result,
                        runID: runID,
                        generation: generation)
                }
            } catch is CancellationError {
                return
            } catch {
                await mainRunLoopScheduler.perform { [weak self] in
                    self?.failAgentExecution(
                        error,
                        runID: runID,
                        generation: generation)
                }
            }
        }
    }

    func finishCommandExecution(generation: Int) {
        guard executionGeneration == generation else { return }
        diagnostics.record(
            category: .command,
            event: "coordinator.command_finished",
            fields: ["generation": String(generation)])
        executionTask = nil
        executingAction = nil
        resumePassiveAfterCooldown()
    }

    func failCommandExecution(_ error: any Error, generation: Int) {
        guard executionGeneration == generation else { return }
        diagnostics.record(
            category: .command,
            event: "coordinator.command_failed",
            level: .error,
            fields: [
                "generation": String(generation),
                "error_type": String(describing: type(of: error)),
            ])
        executionTask = nil
        executingAction = nil
        state = .failed(error.localizedDescription)
        resumePassiveAfterCooldown()
    }

    func publishAgentEvent(
        _ event: AgentRunEvent,
        runID: UUID,
        generation: Int,
        receivedAtUptime: UInt64
    ) {
        guard
            executionGeneration == generation,
            activeAgentRunID == runID
        else {
            diagnostics.record(
                category: .agent,
                event: "coordinator.agent_event_discarded",
                level: .debug,
                fields: [
                    "run_id": runID.uuidString,
                    "event_kind": event.coordinatorDiagnosticName,
                    "event_generation": String(generation),
                    "generation": String(executionGeneration),
                ])
            return
        }
        if event.isMeaningfulAgentActivity {
            agentTurnHadActivity = true
        }
        diagnostics.record(
            category: .agent,
            event: "coordinator.agent_event_published",
            fields: [
                "run_id": runID.uuidString,
                "event_kind": event.coordinatorDiagnosticName,
                "generation": String(generation),
                "meaningful_activity": String(event.isMeaningfulAgentActivity),
                "task_priority": String(Task.currentPriority.rawValue),
                "main_delivery_ms": String(
                    Self.elapsedMilliseconds(since: receivedAtUptime)),
                "run_loop_mode": RunLoop.current.currentMode?.rawValue ?? "none",
            ])
        onAgentRunEvent?(.event(runID: runID, event: event))
    }

    func finishAgentExecution(
        _ result: AgentRunResult,
        runID: UUID,
        generation: Int
    ) {
        guard
            executionGeneration == generation,
            activeAgentRunID == runID
        else { return }
        agentTurnHadActivity = false
        diagnostics.record(
            category: .agent,
            event: "coordinator.agent_turn_finished",
            fields: [
                "run_id": runID.uuidString,
                "generation": String(generation),
                "stop_reason": result.stopReason.rawValue,
                "pending_follow_up_count": String(pendingAgentPrompts.count),
            ])
        onAgentRunEvent?(.turnCompleted(runID: runID, result: result))
        executionTask = nil
        if pendingAgentPrompts.isEmpty {
            state = .executing
        } else {
            startNextAgentPrompt()
        }
    }

    func failAgentExecution(
        _ error: any Error,
        runID: UUID,
        generation: Int
    ) {
        guard
            executionGeneration == generation,
            activeAgentRunID == runID
        else { return }
        let message = error.localizedDescription
        diagnostics.record(
            category: .agent,
            event: "coordinator.agent_turn_failed",
            level: .error,
            fields: [
                "run_id": runID.uuidString,
                "generation": String(generation),
                "had_activity": String(agentTurnHadActivity),
                "error_type": String(describing: type(of: error)),
            ])
        if agentTurnHadActivity {
            agentTurnHadActivity = false
            onAgentRunEvent?(.turnFailed(runID: runID, message: message))
            executionTask = nil
            state = .executing
            return
        }
        agentTurnHadActivity = false
        agentSpeechOutputActive = false
        onAgentRunEvent?(.failed(runID: runID, message: message))
        executionTask = nil
        executingAction = nil
        activeAgentRunID = nil
        pendingAgentPrompts.removeAll()
        agentConversationEndResult = nil
        resetConversationCapture()
        conversationRestartTask?.cancel()
        conversationRestartTask = nil
        stopSpeechSession()
        state = .failed(message)
        resumePassiveAfterCooldown()
    }

    func beginAgentCancellation(runID: UUID) {
        guard agentCancellationTask == nil else { return }

        let token = UUID()
        diagnostics.record(
            category: .agent,
            event: "coordinator.agent_cancellation_started",
            fields: [
                "run_id": runID.uuidString,
                "cancellation_id": token.uuidString,
            ])
        agentCancellationToken = token
        let mainRunLoopScheduler = MainRunLoopScheduler.shared
        agentCancellationTask = Task.detached(priority: .userInitiated) {
            [weak self, agentRunner] in
            await agentRunner.cancel()
            guard !Task.isCancelled else { return }
            mainRunLoopScheduler.schedule { [weak self] in
                guard let self, self.agentCancellationToken == token else { return }
                self.diagnostics.record(
                    category: .agent,
                    event: "coordinator.agent_cancellation_finished",
                    fields: [
                        "run_id": runID.uuidString,
                        "cancellation_id": token.uuidString,
                    ])
                self.agentCancellationTask = nil
                self.agentCancellationToken = nil
                guard self.activeAgentRunID == runID else { return }
                if let result = self.agentConversationEndResult {
                    self.finishAgentConversation(
                        runID: runID,
                        result: result)
                } else if !self.pendingAgentPrompts.isEmpty {
                    self.startNextAgentPrompt()
                } else {
                    self.onAgentRunEvent?(
                        .turnCompleted(
                            runID: runID,
                            result: AgentRunResult(stopReason: .cancelled)))
                    self.state = .executing
                }
            }
        }
    }

    func finishAgentConversation(runID: UUID, result: AgentRunResult) {
        guard activeAgentRunID == runID else { return }
        diagnostics.record(
            category: .agent,
            event: "coordinator.agent_conversation_finished",
            fields: [
                "run_id": runID.uuidString,
                "stop_reason": result.stopReason.rawValue,
            ])
        agentSpeechOutputActive = false
        executionTask?.cancel()
        executionTask = nil
        executingAction = nil
        activeAgentRunID = nil
        pendingAgentPrompts.removeAll()
        agentConversationEndResult = nil
        resetConversationCapture()
        conversationRestartTask?.cancel()
        conversationRestartTask = nil
        stopSpeechSession()
        onAgentRunEvent?(.completed(runID: runID, result: result))
        resumePassiveAfterCooldown()
    }

    func resumePassiveAfterCooldown() {
        let activeExecutionGeneration = executionGeneration
        restartTask?.cancel()
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.passive_resume_scheduled",
            fields: ["generation": String(activeExecutionGeneration)])
        restartTask = MainRunLoopScheduler.shared.schedule(after: timing.executionCooldown) {
            [weak self] in
            guard
                let self,
                self.executionGeneration == activeExecutionGeneration
            else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.passive_resume_fired",
                fields: ["generation": String(activeExecutionGeneration)])
            self.resumePassiveIfNeeded()
        }
    }

    func schedulePassiveRestart() {
        restartTask?.cancel()
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.passive_restart_scheduled")
        restartTask = MainRunLoopScheduler.shared.schedule(after: timing.passiveRestart) {
            [weak self] in
            guard let self else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.passive_restart_fired")
            self.resumePassiveIfNeeded()
        }
    }

    func resumePassiveIfNeeded() {
        if passiveEnabled, !pushToTalkActive {
            startPassiveListening()
        } else if !pushToTalkActive {
            state = .disabled
        }
    }

    func stopActiveSession() {
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.active_session_stopping",
            fields: [
                "generation": String(generation),
                "capture_generation": String(captureGeneration),
            ])
        captureGeneration &+= 1
        resetConversationCapture()
        conversationRestartTask?.cancel()
        conversationRestartTask = nil
        cancelWakeHandoff()
        cancelCaptureInitialSilence()
        inactivityTask?.cancel()
        inactivityTask = nil
        hardStopTask?.cancel()
        hardStopTask = nil
        stopSpeechSession()
    }

    func stopSpeechSession() {
        generation &+= 1
        speechSession.stop()
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.speech_session_stopped",
            fields: ["generation": String(generation)])
    }

    /// Returns whole monotonic milliseconds elapsed since a recorded uptime value.
    nonisolated static func elapsedMilliseconds(since startedAt: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= startedAt ? (now - startedAt) / 1_000_000 : 0
    }
}

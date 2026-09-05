// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

extension VoiceActivationCoordinator {
    func startPassiveListening() {
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.passive_listening_starting")
        stopActiveSession()
        capturedCommand = ""
        currentTranscript = ""
        activeProfile = nil
        capturedAction = nil
        capturedLocaleID = nil

        do {
            let config = try configuration()
            let enabledProfiles = config.profiles.filter(\.isEnabled)
            guard !enabledProfiles.isEmpty else {
                diagnostics.record(
                    category: .speechRecognition,
                    event: "coordinator.passive_listening_not_started",
                    level: .warning,
                    fields: ["reason": "no_enabled_profiles"])
                state = .disabled
                return
            }
            state = .listening
            startSession(
                mode: .passiveWake,
                localeID: config.localeID,
                contextualStrings: enabledProfiles.map(\.wakePhrase))
        } catch {
            diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.passive_listening_failed",
                level: .error,
                fields: ["error_type": String(describing: type(of: error))])
            state = .failed(error.localizedDescription)
        }
    }

    func startSession(
        mode: SpeechSessionMode,
        localeID: String,
        contextualStrings: [String] = []
    ) {
        generation &+= 1
        let activeGeneration = generation
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.session_starting",
            fields: [
                "generation": String(activeGeneration),
                "mode": mode.coordinatorDiagnosticName,
                "contextual_phrase_count": String(contextualStrings.count),
            ])
        do {
            try speechSession.start(
                mode: mode,
                localeID: localeID,
                contextualStrings: contextualStrings,
                onUpdate: { [weak self] update in
                    guard let self, self.generation == activeGeneration else { return }
                    self.handle(update, mode: mode)
                },
                onInterruption: { [weak self] in
                    guard let self, self.generation == activeGeneration else { return }
                    self.handleInterruption(mode: mode)
                })
            diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.session_started",
                fields: [
                    "generation": String(activeGeneration),
                    "mode": mode.coordinatorDiagnosticName,
                ])
        } catch {
            diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.session_start_failed",
                level: .error,
                fields: [
                    "generation": String(activeGeneration),
                    "mode": mode.coordinatorDiagnosticName,
                    "error_type": String(describing: type(of: error)),
                ])
            state = .failed(error.localizedDescription)
            if mode == .conversation {
                scheduleConversationRestart()
            } else if mode == .passiveWake || mode == .commandCapture {
                schedulePassiveRestart()
            }
        }
    }

    func handleInterruption(mode: SpeechSessionMode) {
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.session_interrupted",
            level: .warning,
            fields: ["mode": mode.coordinatorDiagnosticName])
        stopActiveSession()
        capturedCommand = ""
        currentTranscript = ""
        if mode == .pushToTalk {
            pushToTalkActive = false
        }

        if mode == .conversation, isAgentConversationActive {
            state = .executing
            scheduleConversationRestart()
            return
        }

        if passiveEnabled {
            state = .listening
            schedulePassiveRestart()
        } else {
            state = .disabled
        }
    }

    func handle(_ update: SpeechUpdate, mode: SpeechSessionMode) {
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.recognition_update",
            level: update.errorDescription == nil ? .debug : .error,
            fields: [
                "mode": mode.coordinatorDiagnosticName,
                "character_count": String(update.transcript.count),
                "is_final": String(update.isFinal),
                "has_error": String(update.errorDescription != nil),
            ])
        if let error = update.errorDescription {
            stopActiveSession()
            state = .failed(error)
            if mode == .conversation {
                scheduleConversationRestart()
            } else if mode == .passiveWake || mode == .commandCapture {
                schedulePassiveRestart()
            }
            return
        }

        switch mode {
        case .pushToTalk:
            capturedCommand = update.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            currentTranscript = capturedCommand
            if CaptureCancellationMatcher.matches(
                capturedCommand,
                isComplete: update.isFinal)
            {
                if pushToTalkContinuesConversation {
                    pushToTalkActive = false
                    pushToTalkContinuesConversation = false
                    stopActiveSession()
                    state = .executing
                    startConversationListening()
                    cancelAgentConversationFromSpeech()
                } else {
                    cancelCapture()
                }
            }
        case .commandCapture:
            handleCommandCapture(update)
        case .conversation:
            handleConversationCapture(update)
        case .passiveWake:
            handlePassive(update)
        }
    }

    func handlePassive(_ update: SpeechUpdate) {
        let profiles: [WakeProfile]
        let localeID: String
        if state == .capturing, let activeProfile, let capturedLocaleID {
            profiles = [activeProfile]
            localeID = capturedLocaleID
        } else {
            do {
                let config = try configuration()
                profiles = config.profiles
                localeID = config.localeID
            } catch {
                stopActiveSession()
                state = .failed(error.localizedDescription)
                return
            }
        }

        guard
            let match = WakePhraseMatcher.match(
                in: update.transcript,
                profiles: profiles)
        else {
            diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.wake_phrase_not_matched",
                level: .debug,
                fields: [
                    "is_final": String(update.isFinal),
                    "character_count": String(update.transcript.count),
                ])
            if wakeHandoffTask != nil {
                cancelWakeHandoff()
                activeProfile = nil
                capturedAction = nil
                capturedLocaleID = nil
                state = .listening
            }
            if update.isFinal { startPassiveListening() }
            return
        }

        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.wake_phrase_matched",
            fields: [
                "profile_id": match.profile.id.uuidString,
                "command_character_count": String(match.command.count),
                "is_final": String(update.isFinal),
            ])

        if capturedAction == nil {
            activeProfile = match.profile
            capturedAction = match.profile.action
            capturedLocaleID = localeID
        }
        capturedCommand = match.command
        currentTranscript = match.command
        state = .capturing

        if CaptureCancellationMatcher.matches(match.command, isComplete: update.isFinal) {
            cancelCapture()
            return
        }

        guard !match.command.isEmpty else {
            if update.isFinal {
                startCommandCapture(localeID: localeID)
            } else {
                scheduleWakeHandoff(localeID: localeID)
            }
            return
        }

        cancelWakeHandoff()
        cancelCaptureInitialSilence()
        scheduleCaptureInactivity()
        scheduleCaptureHardStop()

        if update.isFinal {
            finishPassiveCapture()
        }
    }

    func startCommandCapture(localeID: String) {
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.command_capture_started")
        stopActiveSession()
        currentTranscript = ""
        state = .capturing
        startSession(mode: .commandCapture, localeID: localeID)
        scheduleCaptureInitialSilence()
        scheduleCaptureHardStop()
    }

    func scheduleWakeHandoff(localeID: String) {
        guard wakeHandoffTask == nil else { return }
        let activeGeneration = generation
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.wake_handoff_scheduled",
            fields: ["generation": String(activeGeneration)])
        wakeHandoffTask = MainRunLoopScheduler.shared.schedule(after: timing.wakeHandoffDelay) {
            [weak self] in
            guard
                let self,
                self.generation == activeGeneration,
                self.capturedCommand.isEmpty
            else { return }
            self.wakeHandoffTask = nil
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.wake_handoff_fired",
                fields: ["generation": String(activeGeneration)])
            self.startCommandCapture(localeID: localeID)
        }
    }

    func cancelWakeHandoff() {
        let wasScheduled = wakeHandoffTask != nil
        wakeHandoffTask?.cancel()
        wakeHandoffTask = nil
        if wasScheduled {
            diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.wake_handoff_cancelled")
        }
    }

    func restartCommandCapture(localeID: String) {
        stopSpeechSession()
        startSession(mode: .commandCapture, localeID: localeID)
    }

    func handleCommandCapture(_ update: SpeechUpdate) {
        capturedCommand = update.transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        currentTranscript = capturedCommand

        if CaptureCancellationMatcher.matches(
            capturedCommand,
            isComplete: update.isFinal)
        {
            cancelCapture()
            return
        }

        guard !capturedCommand.isEmpty else {
            if update.isFinal {
                do {
                    restartCommandCapture(localeID: try configuration().localeID)
                } catch {
                    stopActiveSession()
                    state = .failed(error.localizedDescription)
                }
            }
            return
        }

        cancelCaptureInitialSilence()
        scheduleCaptureInactivity()
        if update.isFinal {
            finishPassiveCapture()
        }
    }

    func startConversationListening() {
        guard
            isAgentConversationActive,
            !pushToTalkActive,
            let localeID = capturedLocaleID
        else {
            diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.conversation_listening_not_started",
                level: .debug,
                fields: [
                    "conversation_active": String(isAgentConversationActive),
                    "push_to_talk_active": String(pushToTalkActive),
                    "has_locale": String(capturedLocaleID != nil),
                ])
            return
        }

        let startedAtUptime = DispatchTime.now().uptimeNanoseconds
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.conversation_listening_started",
            fields: ["task_priority": String(Task.currentPriority.rawValue)])

        resetConversationCapture()
        stopSpeechSession()
        conversationUtterance = ""
        currentTranscript = ""
        state = .executing
        startSession(
            mode: .conversation,
            localeID: localeID,
            contextualStrings: [
                "stop", "cancel", "dismiss", "allow", "allow all", "deny", "deny all",
            ])
        let finishedAtUptime = DispatchTime.now().uptimeNanoseconds
        let duration = finishedAtUptime >= startedAtUptime
            ? (finishedAtUptime - startedAtUptime) / 1_000_000
            : 0
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.conversation_listening_finished",
            fields: [
                "duration_ms": String(duration),
                "task_priority": String(Task.currentPriority.rawValue),
            ])
    }

    func handleConversationCapture(_ update: SpeechUpdate) {
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.conversation_capture_update",
            level: .debug,
            fields: [
                "character_count": String(update.transcript.count),
                "is_final": String(update.isFinal),
                "speech_output_active": String(agentSpeechOutputActive),
            ])
        if agentSpeechOutputActive {
            let transcript = update.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if CaptureCancellationMatcher.matches(transcript, isComplete: update.isFinal) {
                agentSpeechOutputActive = false
                diagnostics.record(
                    category: .agent,
                    event: "coordinator.voice_cancel_during_speech")
                onAgentSpeechCancellation?()
                cancelAgentConversationFromSpeech()
                return
            }
            guard !transcript.isEmpty else {
                currentTranscript = ""
                if update.isFinal {
                    startConversationListening()
                }
                return
            }

            // Clear this before stopping playback. The synchronous speech callback
            // must not replace the recognition session that owns this utterance.
            agentSpeechOutputActive = false
            diagnostics.record(
                category: .audio,
                event: "coordinator.speech_barged_in",
                fields: ["character_count": String(transcript.count)])
            onAgentSpeechCancellation?()
        }

        conversationUtterance = update.transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        currentTranscript = conversationUtterance

        guard !conversationUtterance.isEmpty else {
            if update.isFinal {
                startConversationListening()
            }
            return
        }

        scheduleConversationInactivity()
        scheduleConversationHardStop()
        if update.isFinal {
            finishConversationUtterance()
        }
    }

    func scheduleConversationInactivity() {
        let activeGeneration = conversationCaptureGeneration
        conversationInactivityTask?.cancel()
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.conversation_inactivity_scheduled",
            fields: ["generation": String(activeGeneration)])
        conversationInactivityTask = MainRunLoopScheduler.shared.schedule(
            after: timing.captureInactivity
        ) { [weak self] in
            guard
                let self,
                self.conversationCaptureGeneration == activeGeneration
            else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.conversation_inactivity_fired",
                fields: ["generation": String(activeGeneration)])
            self.finishConversationUtterance()
        }
    }

    func scheduleConversationHardStop() {
        guard conversationHardStopTask == nil else { return }
        let activeGeneration = conversationCaptureGeneration
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.conversation_hard_stop_scheduled",
            fields: ["generation": String(activeGeneration)])
        conversationHardStopTask = MainRunLoopScheduler.shared.schedule(after: timing.captureMaximum) {
            [weak self] in
            guard
                let self,
                self.conversationCaptureGeneration == activeGeneration
            else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.conversation_hard_stop_fired",
                fields: ["generation": String(activeGeneration)])
            self.finishConversationUtterance()
        }
    }

    func finishConversationUtterance() {
        let transcript = conversationUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.conversation_utterance_finished",
            fields: ["character_count": String(transcript.count)])
        startConversationListening()
        guard !transcript.isEmpty else { return }

        if CaptureCancellationMatcher.matches(transcript, isComplete: true) {
            diagnostics.record(
                category: .agent,
                event: "coordinator.conversation_cancel_voice_command")
            cancelAgentConversationFromSpeech()
        } else if onAgentVoiceUtterance?(transcript) == true {
            diagnostics.record(
                category: .agent,
                event: "coordinator.conversation_voice_command_handled")
            return
        } else {
            submitAgentFollowUp(transcript)
        }
    }

    func resetConversationCapture() {
        conversationCaptureGeneration &+= 1
        conversationInactivityTask?.cancel()
        conversationInactivityTask = nil
        conversationHardStopTask?.cancel()
        conversationHardStopTask = nil
    }

    func scheduleConversationRestart() {
        conversationRestartTask?.cancel()
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.conversation_restart_scheduled")
        conversationRestartTask = MainRunLoopScheduler.shared.schedule(after: timing.passiveRestart) {
            [weak self] in
            guard let self, self.isAgentConversationActive else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.conversation_restart_fired")
            self.startConversationListening()
        }
    }

    func scheduleCaptureInitialSilence() {
        guard initialSilenceTask == nil else { return }
        let activeCaptureGeneration = captureGeneration
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.capture_initial_silence_scheduled",
            fields: ["generation": String(activeCaptureGeneration)])
        initialSilenceTask = MainRunLoopScheduler.shared.schedule(
            after: timing.captureInitialSilence
        ) { [weak self] in
            guard
                let self,
                self.captureGeneration == activeCaptureGeneration
            else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.capture_initial_silence_fired",
                fields: ["generation": String(activeCaptureGeneration)])
            self.finishPassiveCapture()
        }
    }

    func cancelCaptureInitialSilence() {
        initialSilenceTask?.cancel()
        initialSilenceTask = nil
    }

    func scheduleCaptureInactivity() {
        let activeCaptureGeneration = captureGeneration
        inactivityTask?.cancel()
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.capture_inactivity_scheduled",
            fields: ["generation": String(activeCaptureGeneration)])
        inactivityTask = MainRunLoopScheduler.shared.schedule(after: timing.captureInactivity) {
            [weak self] in
            guard
                let self,
                self.captureGeneration == activeCaptureGeneration
            else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.capture_inactivity_fired",
                fields: ["generation": String(activeCaptureGeneration)])
            self.finishPassiveCapture()
        }
    }

    func scheduleCaptureHardStop() {
        guard hardStopTask == nil else { return }
        let activeCaptureGeneration = captureGeneration
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.capture_hard_stop_scheduled",
            fields: ["generation": String(activeCaptureGeneration)])
        hardStopTask = MainRunLoopScheduler.shared.schedule(after: timing.captureMaximum) {
            [weak self] in
            guard
                let self,
                self.captureGeneration == activeCaptureGeneration
            else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "coordinator.capture_hard_stop_fired",
                fields: ["generation": String(activeCaptureGeneration)])
            self.finishPassiveCapture()
        }
    }

    func finishPassiveCapture() {
        let transcript = capturedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        diagnostics.record(
            category: .speechRecognition,
            event: "coordinator.capture_finished",
            fields: ["character_count": String(transcript.count)])

        if CaptureCancellationMatcher.matches(transcript, isComplete: true) {
            cancelCapture()
            return
        }

        stopActiveSession()
        guard !transcript.isEmpty else {
            resumePassiveIfNeeded()
            return
        }
        execute(transcript)
    }

}

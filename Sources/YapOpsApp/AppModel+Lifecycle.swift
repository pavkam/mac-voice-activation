// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import YapOpsCore

enum AppModelStartupPhase {
    case idle
    case starting
    case ready
}

enum AppModelEffectAuthorization: Equatable {
    case startup(UInt64)
    case ready(UInt64)
}

extension AppModel {
    var isStartupReady: Bool { startupPhase == .ready }

    var readyEffectAuthorization: AppModelEffectAuthorization? {
        guard startupPhase == .ready, !isShutdown else { return nil }
        return .ready(startupGeneration)
    }

    func isEffectAuthorized(_ authorization: AppModelEffectAuthorization) -> Bool {
        guard !isShutdown else { return false }
        switch authorization {
        case .startup(let generation):
            return startupPhase == .starting && startupGeneration == generation
        case .ready(let generation):
            return startupPhase == .ready && startupGeneration == generation
        }
    }

    func cancelStartupAttempt() {
        guard startupPhase == .starting else { return }
        invalidateStartupAttempt(generation: startupGeneration)
    }

    /// Idempotently stops every adapter and flushes diagnostics before application exit.
    func shutdown() async {
        guard !isShutdown else {
            diagnostics.record(category: .app, event: "app_model.shutdown_ignored")
            if !isShutdownComplete {
                await withCheckedContinuation { shutdownWaiters.append($0) }
            }
            return
        }
        diagnostics.record(category: .app, event: "app_model.shutdown_started")
        invalidateStartupAttempt(generation: startupGeneration, force: true)
        isShutdown = true
        heldHotKeyProfileID = nil
        shortcut.stop()
        agentSessionHandlerGeneration &+= 1
        await agentRunner.setSessionEventHandler(nil)
        coordinator.stop()
        overlayPresenter.update(state: .disabled, transcript: "")
        if let runID = agentRunSnapshot?.runID {
            agentRunPanelPresenter.hide(runID: runID)
        }
        await agentRunPanelPresenter.shutdown()
        agentRunPresentation.shutdown()
        agentRunSnapshot = nil
        agentSessionPresentationRegistry.removeAll()
        agentConversationAudioPresenter.shutdown()
        for backendID in Array(textToSpeechVoiceCatalogGenerations.keys) {
            textToSpeechVoiceCatalogGenerations[backendID, default: 0] &+= 1
        }
        loadingTextToSpeechBackendIDs.removeAll()
        credentialLoadTask?.cancel()
        textToSpeechVoicePreviewGeneration &+= 1
        activeTextToSpeechVoicePreviewContext = nil
        textToSpeechVoicePreview.stop()
        diagnostics.record(category: .app, event: "app_model.shutdown_finished")
        diagnostics.flush()
        isShutdownComplete = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Updates only the editable shortcut draft for a profile.
    func setPushToTalkHotKey(_ hotKey: PushToTalkHotKey?, for profileID: UUID) {
        guard let index = wakeProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        guard wakeProfiles[index].pushToTalkHotKey != hotKey else { return }
        wakeProfiles[index].pushToTalkHotKey = hotKey
        settingsError = nil
        diagnostics.record(
            category: .settings,
            event: "settings.hot_key_draft_changed",
            fields: [
                "profile_id": profileID.uuidString,
                "has_hot_key": String(hotKey != nil),
            ])
    }

    /// Suspends global shortcut registration while Settings captures a replacement binding.
    func setPushToTalkShortcutRecording(_ recording: Bool) {
        guard isStartupReady else { return }
        guard recording != recordingShortcut else { return }
        recordingShortcut = recording
        diagnostics.record(
            category: .hotKey,
            event: "hot_key.recording_changed",
            fields: ["recording": String(recording)])
        if recording {
            shortcut.stop()
            return
        }

        do {
            try registerShortcuts(activeWakeProfiles)
        } catch {
            settingsError = error.localizedDescription
            diagnostics.record(
                category: .hotKey,
                event: "hot_key.registration_restore_failed",
                level: .error,
                fields: ["error_type": String(describing: type(of: error))])
        }
    }

    /// Wires coordinator callbacks, restores shortcuts, and starts permitted passive listening.
    @discardableResult
    func start() async -> Bool {
        guard !isShutdown else {
            diagnostics.record(
                category: .app,
                event: "app_model.start_ignored",
                fields: ["reason": "shutdown"])
            return false
        }
        switch startupPhase {
        case .ready:
            diagnostics.record(
                category: .app,
                event: "app_model.start_ignored",
                fields: ["reason": "already_ready"])
            return true
        case .starting:
            diagnostics.record(
                category: .app,
                event: "app_model.start_ignored",
                fields: ["reason": "already_starting"])
            return false
        case .idle:
            break
        }
        startupGeneration &+= 1
        let generation = startupGeneration
        startupPhase = .starting
        diagnostics.record(category: .app, event: "app_model.start_started")
        return await withTaskCancellationHandler {
            await performStart(generation: generation)
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.invalidateStartupAttempt(generation: generation)
            }
        }
    }

    private func performStart(generation: UInt64) async -> Bool {
        let authorization = AppModelEffectAuthorization.startup(generation)
        do {
            let interrupted = try await continuityStore.reconcileInterruptedWork()
            guard ownsStartupAttempt(generation) else { return false }
            publishInterruptedAgentWork(interrupted)
        } catch is CancellationError {
            invalidateStartupAttempt(generation: generation)
            return false
        } catch {
            guard ownsStartupAttempt(generation) else { return false }
            diagnostics.record(
                category: .app,
                event: "continuity_store.read_failed",
                level: .error,
                fields: ["failure_category": "launch_reconcile"])
        }
        guard ownsStartupAttempt(generation) else { return false }
        refreshMacContextAccessStatus(authorization: authorization)
        guard ownsStartupAttempt(generation) else { return false }
        guard await loadCredential(startupGeneration: generation) else { return false }
        guard ownsStartupAttempt(generation) else { return false }
        await installAgentSessionEventHandler()
        guard ownsStartupAttempt(generation) else { return false }
        coordinator.onStateChange = { [weak self] in
            guard let self else { return }
            if $0 == .capturing {
                // The recording overlay is about to take this spot back.
                self.actionFeedbackPresenter.dismiss()
                self.pendingAgentHandoff = nil
            } else if $0 == .executing, self.pendingAgentHandoff == nil {
                self.pendingAgentHandoff = self.overlayPresenter.takeAgentRunHandoff()
            } else if $0 != .executing {
                self.pendingAgentHandoff = nil
            }
            self.state = $0
            self.diagnostics.record(
                category: .ui,
                event: "app_model.state_published",
                fields: ["state": $0.appModelDiagnosticName])
            self.soundPresenter.update(state: $0)
            self.updateRecordingOverlay()
        }
        coordinator.onTranscriptChange = { [weak self] in self?.lastTranscript = $0 }
        coordinator.onCurrentTranscriptChange = { [weak self] in
            guard let self else { return }
            self.currentTranscript = $0
            if let snapshot = self.agentRunSnapshot, !snapshot.phase.isTerminal {
                self.agentRunPresentation.updateVoiceInput(
                    runID: snapshot.runID,
                    transcript: $0)
            }
            self.updateRecordingOverlay()
        }
        coordinator.onActiveProfileChange = { [weak self] in
            self?.activeProfile = $0
            self?.updateRecordingOverlay()
        }
        coordinator.onAgentRunEvent = { [weak self] event in
            self?.handleAgentRunLifecycleEvent(event)
        }
        coordinator.onActionFeedback = { [weak self] event in
            self?.actionFeedbackPresenter.handle(event)
        }
        coordinator.onAgentSpeechCancellation = { [weak self] in
            self?.diagnostics.record(
                category: .audio,
                event: "app_model.agent_speech_cancel_received")
            self?.agentConversationAudioPresenter.interruptSpeech()
        }
        coordinator.onAgentVoiceUtterance = { [weak self] utterance in
            self?.handleAgentVoiceUtterance(utterance) ?? false
        }
        do {
            try registerShortcuts(activeWakeProfiles, authorization: authorization)
        } catch {
            guard ownsStartupAttempt(generation) else { return false }
            settingsError = error.localizedDescription
            diagnostics.record(
                category: .hotKey,
                event: "app_model.hot_key_start_failed",
                level: .error,
                fields: ["error_type": String(describing: type(of: error))])
        }

        guard passiveEnabled else {
            guard markStartupReady(generation) else { return false }
            diagnostics.record(
                category: .app,
                event: "app_model.start_finished",
                fields: ["passive_listening_started": "false"])
            return true
        }
        guard await ensurePermissions(authorization: authorization) else {
            guard ownsStartupAttempt(generation) else { return false }
            guard markStartupReady(generation) else { return false }
            diagnostics.record(
                category: .app,
                event: "app_model.start_finished",
                fields: ["passive_listening_started": "false"])
            return true
        }
        guard ownsStartupAttempt(generation) else { return false }
        guard passiveEnabled else {
            guard markStartupReady(generation) else { return false }
            diagnostics.record(
                category: .app,
                event: "app_model.start_finished",
                fields: ["passive_listening_started": "false"])
            return true
        }
        coordinator.setPassiveEnabled(true)
        guard markStartupReady(generation) else {
            coordinator.setPassiveEnabled(false)
            return false
        }
        diagnostics.record(
            category: .app,
            event: "app_model.start_finished",
            fields: ["passive_listening_started": "true"])
        return true
    }

    private func ownsStartupAttempt(_ generation: UInt64) -> Bool {
        !Task.isCancelled
            && isEffectAuthorized(.startup(generation))
    }

    private func markStartupReady(_ generation: UInt64) -> Bool {
        guard ownsStartupAttempt(generation) else { return false }
        startupPhase = .ready
        return true
    }

    private func invalidateStartupAttempt(generation: UInt64, force: Bool = false) {
        guard force || (startupPhase == .starting && startupGeneration == generation) else {
            return
        }
        startupGeneration &+= 1
        startupPhase = .idle
        heldHotKeyProfileID = nil
        permissionTask?.cancel()
        permissionTask = nil
        permissionAuthorization = nil
        credentialLoadTask?.cancel()
        credentialLoadTask = nil
        credentialLoadGeneration = nil
    }

    /// Replaces launch interruption state with a deterministic bounded snapshot.
    func publishInterruptedAgentWork(_ markers: [AgentInterruptedWorkMarker]) {
        let bounded = Array(markers.lazy.filter {
            $0.state == .interruptedByProcessExit
        }.prefix(AgentContinuityStorePolicy.maximumRecords))
        interruptedAgentWork = bounded
        pendingInterruptedAgentWork = Dictionary(grouping: bounded.lazy.filter {
            $0.providerTaskID == nil
        }, by: { $0.key.profileID })
    }

    /// Supplies exact ordinary interruption markers for the selected profile.
    func agentRunContinuityRequest(for profileID: UUID) -> AgentRunContinuityRequest {
        let markers = pendingInterruptedAgentWork[profileID] ?? []
        return AgentRunContinuityRequest(
            previousTurnInterrupted: !markers.isEmpty,
            interruptedWork: markers,
            onPublishedAcknowledgement: { [weak self] acknowledgedKeys in
                await self?.consumeInterruptedAgentWork(
                    acknowledgedKeys,
                    profileID: profileID)
            })
    }

    private func consumeInterruptedAgentWork(
        _ acknowledgedKeys: Set<AgentInterruptedWorkKey>,
        profileID: UUID
    ) {
        let exactKeys = Set(acknowledgedKeys.filter { $0.profileID == profileID })
        guard !exactKeys.isEmpty,
            let pending = pendingInterruptedAgentWork[profileID]
        else { return }
        let retained = pending.filter { !exactKeys.contains($0.key) }
        if retained.isEmpty {
            pendingInterruptedAgentWork.removeValue(forKey: profileID)
        } else {
            pendingInterruptedAgentWork[profileID] = retained
        }
        interruptedAgentWork.removeAll {
            $0.providerTaskID == nil && exactKeys.contains($0.key)
        }
    }

    func discardInterruptedAgentWork(profileIDs: Set<UUID>) {
        for profileID in profileIDs {
            pendingInterruptedAgentWork.removeValue(forKey: profileID)
        }
        interruptedAgentWork.removeAll { profileIDs.contains($0.key.profileID) }
    }

    private func loadCredential(startupGeneration generation: UInt64) async -> Bool {
        guard ownsStartupAttempt(generation) else { return false }
        let initialDraft = elevenLabsAPIKey
        let startedAtUptime = DispatchTime.now().uptimeNanoseconds
        diagnostics.record(
            category: .settings,
            event: "credential_load.started",
            fields: ["task_priority": String(Task.currentPriority.rawValue)])
        let task = Task(priority: .userInitiated) { @MainActor [weak self, agentSpeechCredentialStore] in
            guard let self,
                self.ownsStartupAttempt(generation)
            else { throw CancellationError() }
            let value = try await agentSpeechCredentialStore.loadElevenLabsAPIKey()
            try Task.checkCancellation()
            return value
        }
        credentialLoadTask = task
        credentialLoadGeneration = generation
        do {
            let storedAPIKey = try await task.value ?? ""
            guard ownsStartupAttempt(generation) else { return false }
            clearCredentialLoad(generation: generation)
            let applied = elevenLabsAPIKey == initialDraft
            if applied {
                elevenLabsAPIKey = storedAPIKey
                agentSpeechSettingsState.update(
                    defaultSelection: defaultSpeechVoice,
                    elevenLabsAPIKey: storedAPIKey)
            }
            diagnostics.record(
                category: .settings,
                event: "credential_load.finished",
                fields: [
                    "cloud_api_configured": String(!storedAPIKey.isEmpty),
                    "applied_to_draft": String(applied),
                    "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
                    "task_priority": String(Task.currentPriority.rawValue),
                ])
            return true
        } catch is CancellationError {
            clearCredentialLoad(generation: generation)
            return false
        } catch {
            guard ownsStartupAttempt(generation) else { return false }
            clearCredentialLoad(generation: generation)
            diagnostics.record(
                category: .settings,
                event: "credential_load.failed",
                level: .error,
                fields: [
                    "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
                    "error_type": String(describing: type(of: error)),
                    "task_priority": String(Task.currentPriority.rawValue),
                ])
            return true
        }
    }

    private func clearCredentialLoad(generation: UInt64) {
        guard credentialLoadGeneration == generation else { return }
        credentialLoadTask = nil
        credentialLoadGeneration = nil
    }

    static func elapsedMilliseconds(since startedAt: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= startedAt ? (now - startedAt) / 1_000_000 : 0
    }

    /// Replaces the active Carbon registrations with the validated profile shortcut set.
    func registerShortcuts(_ profiles: [WakeProfile]) throws {
        guard let authorization = readyEffectAuthorization else {
            throw ModelError.unavailable
        }
        try registerShortcuts(profiles, authorization: authorization)
    }

    func registerShortcuts(
        _ profiles: [WakeProfile],
        authorization: AppModelEffectAuthorization
    ) throws {
        guard isEffectAuthorized(authorization) else { throw CancellationError() }
        try shortcut.start(
            profiles: profiles,
            onPressed: { [weak self] in self?.pushToTalkPressed(profileID: $0) },
            onReleased: { [weak self] in self?.pushToTalkReleased(profileID: $0) })
    }

    /// Validates executable and working-directory paths without launching profile actions.
    func validateFileSystem(_ profiles: [WakeProfile]) throws {
        for profile in profiles {
            switch profile.action {
            case .command(let command):
                guard isExecutableFile(command.executablePath) else {
                    throw SettingsValidationError.executableIsNotRunnable(
                        command.executablePath)
                }
            case .agent(let configuration):
                guard isExecutableFile(configuration.executablePath) else {
                    throw SettingsValidationError.agentExecutableIsNotRunnable(
                        configuration.executablePath)
                }
                guard isDirectory(configuration.workingDirectory) else {
                    throw SettingsValidationError.workingDirectoryIsNotDirectory(
                        configuration.workingDirectory)
                }
            case .systemAction:
                // System actions address macOS subsystems, not files, so there
                // is no path to validate before saving.
                continue
            }
        }
    }

    /// Ensures every inherited or profile-specific speech selection can run.
    func validateAgentSpeechSettings(profiles: [WakeProfile]) throws {
        try validateAgentSpeechSettings(
            profiles: profiles,
            readsAgentRepliesAloud: readsAgentRepliesAloud,
            defaultSpeechVoice: defaultSpeechVoice,
            elevenLabsAPIKey: elevenLabsAPIKey)
    }

    func validateAgentSpeechSettings(
        profiles: [WakeProfile],
        readsAgentRepliesAloud: Bool,
        defaultSpeechVoice: TextToSpeechVoiceSelection,
        elevenLabsAPIKey: String
    ) throws {
        var selections: [TextToSpeechVoiceSelection] = []
        if readsAgentRepliesAloud {
            selections.append(defaultSpeechVoice)
        }
        selections.append(contentsOf: profiles.compactMap { profile in
            guard case .voice(let selection) = profile.speechPreference else { return nil }
            return selection
        })
        let availableBackendIDs = Set(textToSpeechBackends.map(\.id))
        for selection in selections {
            guard availableBackendIDs.contains(selection.backendID) else {
                throw SettingsValidationError.textToSpeechBackendUnavailable(
                    selection.backendID.rawValue)
            }
            guard selection.backendID == .elevenLabs else { continue }
            guard !elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SettingsValidationError.elevenLabsAPIKeyRequired
            }
            guard selection.voiceID != nil else {
                throw SettingsValidationError.elevenLabsVoiceIDRequired
            }
        }
    }

    /// Finds cached agent sessions invalidated by changed or removed saved profiles.
    func agentProfileIDsToReset(
        oldProfiles: [WakeProfile],
        newProfiles: [WakeProfile]
    ) -> Set<UUID> {
        let newProfilesByID = Dictionary(uniqueKeysWithValues: newProfiles.map { ($0.id, $0) })
        return Set(
            oldProfiles.compactMap { oldProfile in
                guard case .agent(let oldConfiguration) = oldProfile.action else { return nil }
                guard let newProfile = newProfilesByID[oldProfile.id] else { return oldProfile.id }
                switch newProfile.action {
                case .command, .systemAction:
                    return oldProfile.id
                case .agent(let newConfiguration):
                    let oldFingerprint = AgentProviderFingerprint.make(
                        configuration: oldConfiguration)
                    let newFingerprint = AgentProviderFingerprint.make(
                        configuration: newConfiguration)
                    return oldFingerprint == newFingerprint ? nil : oldProfile.id
                }
            })
    }

    /// Begins profile-identified push-to-talk after lazily obtaining speech permission.
    func pushToTalkPressed(profileID: UUID) {
        diagnostics.record(
            category: .hotKey,
            event: "app_model.push_to_talk_pressed",
            fields: ["profile_id": profileID.uuidString])
        guard isStartupReady, !isShutdown, heldHotKeyProfileID == nil else {
            diagnostics.record(
                category: .hotKey,
                event: "app_model.push_to_talk_ignored",
                fields: [
                    "reason": !isStartupReady
                        ? "startup_not_ready"
                        : isShutdown ? "shutdown" : "another_binding_held",
                ])
            return
        }
        heldHotKeyProfileID = profileID
        Task(priority: .userInitiated) { @MainActor [weak self] in
            guard let self,
                await self.ensurePermissions(),
                self.heldHotKeyProfileID == profileID
            else { return }
            self.coordinator.pushToTalkPressed(profileID: profileID)
        }
    }

    /// Ends only the shortcut capture whose profile still owns the held binding.
    func pushToTalkReleased(profileID: UUID) {
        guard heldHotKeyProfileID == profileID else {
            diagnostics.record(
                category: .hotKey,
                event: "app_model.push_to_talk_release_ignored",
                fields: ["profile_id": profileID.uuidString])
            return
        }
        diagnostics.record(
            category: .hotKey,
            event: "app_model.push_to_talk_released",
            fields: ["profile_id": profileID.uuidString])
        heldHotKeyProfileID = nil
        coordinator.pushToTalkReleased()
    }

}

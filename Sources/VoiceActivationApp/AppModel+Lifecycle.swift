// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import VoiceActivationCore

extension AppModel {
    /// Idempotently stops every adapter and flushes diagnostics before application exit.
    func shutdown() {
        guard !isShutdown else {
            diagnostics.record(category: .app, event: "app_model.shutdown_ignored")
            return
        }
        diagnostics.record(category: .app, event: "app_model.shutdown_started")
        isShutdown = true
        heldHotKeyProfileID = nil
        shortcut.stop()
        coordinator.stop()
        overlayPresenter.update(state: .disabled, transcript: "")
        if let runID = agentRunSnapshot?.runID {
            agentRunPanelPresenter.hide(runID: runID)
        }
        agentRunPresentation.shutdown()
        agentConversationAudioPresenter.shutdown()
        elevenLabsVoiceCatalogGeneration &+= 1
        credentialLoadTask?.cancel()
        elevenLabsVoicePreview.stop()
        diagnostics.record(category: .app, event: "app_model.shutdown_finished")
        diagnostics.flush()
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
    func start() async {
        guard !started, !isShutdown else {
            diagnostics.record(
                category: .app,
                event: "app_model.start_ignored",
                fields: [
                    "already_started": String(started),
                    "shutdown": String(isShutdown),
                ])
            return
        }
        started = true
        diagnostics.record(category: .app, event: "app_model.start_started")
        startCredentialLoad()
        coordinator.onStateChange = { [weak self] in
            guard let self else { return }
            if $0 == .capturing {
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
        coordinator.onAgentSpeechCancellation = { [weak self] in
            self?.diagnostics.record(
                category: .audio,
                event: "app_model.agent_speech_cancel_received")
            self?.agentConversationAudioPlayer.stopSpeaking()
        }
        coordinator.onAgentVoiceUtterance = { [weak self] utterance in
            self?.handleAgentVoiceUtterance(utterance) ?? false
        }
        do {
            try registerShortcuts(activeWakeProfiles)
        } catch {
            settingsError = error.localizedDescription
            diagnostics.record(
                category: .hotKey,
                event: "app_model.hot_key_start_failed",
                level: .error,
                fields: ["error_type": String(describing: type(of: error))])
        }

        guard passiveEnabled else {
            diagnostics.record(
                category: .app,
                event: "app_model.start_finished",
                fields: ["passive_listening_started": "false"])
            return
        }
        guard await ensurePermissions(), passiveEnabled, !isShutdown else {
            diagnostics.record(
                category: .app,
                event: "app_model.start_finished",
                fields: ["passive_listening_started": "false"])
            return
        }
        coordinator.setPassiveEnabled(true)
        diagnostics.record(
            category: .app,
            event: "app_model.start_finished",
            fields: ["passive_listening_started": "true"])
    }

    /// Loads the Keychain credential off the launch path and publishes it when available.
    func startCredentialLoad() {
        guard credentialLoadTask == nil else {
            diagnostics.record(
                category: .settings,
                event: "credential_load.ignored",
                fields: ["reason": "already_started"])
            return
        }

        let initialDraft = elevenLabsAPIKey
        let startedAtUptime = DispatchTime.now().uptimeNanoseconds
        diagnostics.record(
            category: .settings,
            event: "credential_load.started",
            fields: ["task_priority": String(Task.currentPriority.rawValue)])
        credentialLoadTask = Task(priority: .userInitiated) {
            @MainActor [weak self, agentSpeechCredentialStore, diagnostics] in
            do {
                let storedAPIKey = try await agentSpeechCredentialStore.loadElevenLabsAPIKey() ?? ""
                try Task.checkCancellation()
                guard let self, !self.isShutdown else { return }

                let applied = self.elevenLabsAPIKey == initialDraft
                if applied {
                    self.elevenLabsAPIKey = storedAPIKey
                    self.agentSpeechSettingsState.update(
                        provider: self.agentSpeechProvider,
                        elevenLabsAPIKey: storedAPIKey,
                        elevenLabsVoiceID: self.elevenLabsVoiceID)
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
            } catch is CancellationError {
                diagnostics.record(
                    category: .settings,
                    event: "credential_load.cancelled",
                    fields: [
                        "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
                        "task_priority": String(Task.currentPriority.rawValue),
                    ])
            } catch {
                diagnostics.record(
                    category: .settings,
                    event: "credential_load.failed",
                    level: .error,
                    fields: [
                        "duration_ms": String(Self.elapsedMilliseconds(since: startedAtUptime)),
                        "error_type": String(describing: type(of: error)),
                        "task_priority": String(Task.currentPriority.rawValue),
                    ])
            }
        }
    }

    static func elapsedMilliseconds(since startedAt: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= startedAt ? (now - startedAt) / 1_000_000 : 0
    }

    /// Replaces the active Carbon registrations with the validated profile shortcut set.
    func registerShortcuts(_ profiles: [WakeProfile]) throws {
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
            }
        }
    }

    /// Ensures cloud speech has a credential and voice before Settings commits it.
    func validateAgentSpeechSettings() throws {
        guard agentSpeechProvider == .elevenLabs else { return }
        guard !elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SettingsValidationError.elevenLabsAPIKeyRequired
        }
        guard !elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SettingsValidationError.elevenLabsVoiceIDRequired
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
                case .command:
                    return oldProfile.id
                case .agent(let newConfiguration):
                    return oldConfiguration == newConfiguration ? nil : oldProfile.id
                }
            })
    }

    /// Begins profile-identified push-to-talk after lazily obtaining speech permission.
    func pushToTalkPressed(profileID: UUID) {
        diagnostics.record(
            category: .hotKey,
            event: "app_model.push_to_talk_pressed",
            fields: ["profile_id": profileID.uuidString])
        guard !isShutdown, heldHotKeyProfileID == nil else {
            diagnostics.record(
                category: .hotKey,
                event: "app_model.push_to_talk_ignored",
                fields: ["reason": isShutdown ? "shutdown" : "another_binding_held"])
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

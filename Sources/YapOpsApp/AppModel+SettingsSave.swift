// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import YapOpsCore

private struct AppModelSettingsSaveSnapshot {
    let generation: UInt64
    let effectAuthorization: AppModelEffectAuthorization
    let drafts: [WakeProfileDraft]
    let activeProfiles: [WakeProfile]
    let localeID: String
    let readsAgentRepliesAloud: Bool
    let playsAgentWorkingSound: Bool
    let capturesMacContext: Bool
    let terminalPhrases: [String]
    let defaultSpeechVoice: TextToSpeechVoiceSelection
    let elevenLabsVoiceID: String
    let elevenLabsAPIKey: String

    var normalizedAPIKey: String {
        elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension AppModel {
    /// Validates and commits one immutable Settings snapshot.
    ///
    /// Cancellation and editor drift can abort before system settings are applied.
    /// Once shortcut and credential application succeeds, the captured reset and
    /// preference commit finish as one serialized transaction while newer editor
    /// drafts remain untouched.
    ///
    /// - Returns: `true` after the captured snapshot commits; otherwise `false`.
    @discardableResult
    func saveSettings() async -> Bool {
        guard let effectAuthorization = readyEffectAuthorization else {
            settingsError = "YapOps is still starting. Try again."
            return false
        }
        guard !isSavingSettings else {
            diagnostics.record(
                category: .settings,
                event: "settings.save_ignored",
                fields: ["reason": "already_saving"])
            return false
        }
        isSavingSettings = true
        defer { isSavingSettings = false }
        settingsSaveGeneration &+= 1
        let snapshot = settingsSaveSnapshot(
            generation: settingsSaveGeneration,
            effectAuthorization: effectAuthorization)
        diagnostics.record(
            category: .settings,
            event: "settings.save_started",
            fields: [
                "profile_count": String(snapshot.drafts.count),
                "speech_backend": snapshot.defaultSpeechVoice.backendID.rawValue,
                "reads_replies": String(snapshot.readsAgentRepliesAloud),
                "plays_working_sound": String(snapshot.playsAgentWorkingSound),
            ])

        guard !Task.isCancelled, !isShutdown else {
            recordAbortedSettingsSave(stage: "before_validation")
            return false
        }

        let profiles: [WakeProfile]
        do {
            profiles = try snapshot.drafts.map { try $0.validatedProfile() }
            try WakeProfileCollectionValidator.validate(profiles)
            try validateFileSystem(profiles)
            try validateAgentSpeechSettings(
                profiles: profiles,
                readsAgentRepliesAloud: snapshot.readsAgentRepliesAloud,
                defaultSpeechVoice: snapshot.defaultSpeechVoice,
                elevenLabsAPIKey: snapshot.normalizedAPIKey)
        } catch {
            settingsError = error.localizedDescription
            recordSettingsSaveFailure(stage: "validation", error: error)
            return false
        }

        guard
            !Task.isCancelled,
            !isShutdown,
            isEffectAuthorized(snapshot.effectAuthorization),
            settingsSaveGeneration == snapshot.generation,
            settingsEditorsMatch(snapshot)
        else {
            recordAbortedSettingsSave(stage: "before_application")
            return false
        }

        do {
            try registerShortcuts(
                profiles,
                authorization: snapshot.effectAuthorization)
        } catch {
            settingsError = error.localizedDescription
            recordSettingsSaveFailure(stage: "hot_key_registration", error: error)
            return false
        }

        credentialLoadTask?.cancel()
        guard isEffectAuthorized(snapshot.effectAuthorization), !Task.isCancelled else {
            try? registerShortcuts(
                snapshot.activeProfiles,
                authorization: snapshot.effectAuthorization)
            recordAbortedSettingsSave(stage: "before_credential_storage")
            return false
        }
        do {
            try agentSpeechCredentialStore.saveElevenLabsAPIKey(
                snapshot.normalizedAPIKey.isEmpty ? nil : snapshot.normalizedAPIKey)
        } catch {
            try? registerShortcuts(
                snapshot.activeProfiles,
                authorization: snapshot.effectAuthorization)
            settingsError = error.localizedDescription
            recordSettingsSaveFailure(stage: "credential_storage", error: error)
            return false
        }

        let profileIDsToReset = agentProfileIDsToReset(
            oldProfiles: snapshot.activeProfiles,
            newProfiles: profiles)
        // Point of no return: cancellation and editor drift no longer abandon the
        // captured profile fence, durable reset, and preference commit.
        diagnostics.record(
            category: .settings,
            event: "settings.save_application_started",
            fields: ["reset_agent_session_count": String(profileIDsToReset.count)])
        if !profileIDsToReset.isEmpty {
            coordinator.invalidateAgentProfiles(profileIDsToReset)
            agentSessionPresentationRegistry.remove(profileIDs: profileIDsToReset)
            await agentRunner.reset(profileIDs: profileIDsToReset)
            discardInterruptedAgentWork(profileIDs: profileIDsToReset)
        }

        commitSettingsSnapshot(
            snapshot,
            profiles: profiles,
            resetProfileIDs: profileIDsToReset)
        return true
    }

    private func settingsSaveSnapshot(
        generation: UInt64,
        effectAuthorization: AppModelEffectAuthorization
    ) -> AppModelSettingsSaveSnapshot {
        AppModelSettingsSaveSnapshot(
            generation: generation,
            effectAuthorization: effectAuthorization,
            drafts: wakeProfiles,
            activeProfiles: activeWakeProfiles,
            localeID: localeID,
            readsAgentRepliesAloud: readsAgentRepliesAloud,
            playsAgentWorkingSound: playsAgentWorkingSound,
            capturesMacContext: capturesMacContext,
            terminalPhrases: terminalPhrases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            defaultSpeechVoice: defaultSpeechVoice,
            elevenLabsVoiceID: elevenLabsVoiceID,
            elevenLabsAPIKey: elevenLabsAPIKey)
    }

    private func settingsEditorsMatch(_ snapshot: AppModelSettingsSaveSnapshot) -> Bool {
        wakeProfiles == snapshot.drafts
            && activeWakeProfiles == snapshot.activeProfiles
            && localeID == snapshot.localeID
            && readsAgentRepliesAloud == snapshot.readsAgentRepliesAloud
            && playsAgentWorkingSound == snapshot.playsAgentWorkingSound
            && capturesMacContext == snapshot.capturesMacContext
            && terminalPhrases == snapshot.terminalPhrases
            && defaultSpeechVoice == snapshot.defaultSpeechVoice
            && elevenLabsVoiceID == snapshot.elevenLabsVoiceID
            && elevenLabsAPIKey == snapshot.elevenLabsAPIKey
    }

    private func commitSettingsSnapshot(
        _ snapshot: AppModelSettingsSaveSnapshot,
        profiles: [WakeProfile],
        resetProfileIDs: Set<UUID>
    ) {
        preferences.wakeProfiles = profiles
        preferences.localeID = snapshot.localeID
        preferences.readsAgentRepliesAloud = snapshot.readsAgentRepliesAloud
        preferences.playsAgentWorkingSound = snapshot.playsAgentWorkingSound
        preferences.agentSpeechProvider = snapshot.defaultSpeechVoice.backendID == .elevenLabs
            ? .elevenLabs
            : .system
        preferences.elevenLabsVoiceID = snapshot.elevenLabsVoiceID
        preferences.defaultSpeechVoice = snapshot.defaultSpeechVoice
        preferences.capturesMacContext = snapshot.capturesMacContext
        preferences.terminalPhrases = snapshot.terminalPhrases

        let previousSpeechConfiguration = agentSpeechSettingsState.configuration
        agentSpeechSettingsState.update(
            defaultSelection: snapshot.defaultSpeechVoice,
            elevenLabsAPIKey: snapshot.normalizedAPIKey)
        agentConversationAudioPresenter.refreshSettings()
        activeWakeProfiles = profiles
        if wakeProfiles == snapshot.drafts {
            wakeProfiles = profiles.map(WakeProfileDraft.init)
        }
        if localeID == snapshot.localeID {
            localeID = preferences.localeID
        }
        if elevenLabsAPIKey == snapshot.elevenLabsAPIKey {
            elevenLabsAPIKey = snapshot.normalizedAPIKey
        }
        if elevenLabsVoiceID == snapshot.elevenLabsVoiceID {
            elevenLabsVoiceID = preferences.elevenLabsVoiceID
        }
        if terminalPhrases == snapshot.terminalPhrases {
            terminalPhrases = preferences.terminalPhrases
        }
        macContextCapturer.setEnabled(snapshot.capturesMacContext)
        settingsError = nil
        coordinator.refreshConfiguration()
        diagnostics.record(
            category: .settings,
            event: "settings.save_finished",
            fields: [
                "profile_count": String(profiles.count),
                "reset_agent_session_count": String(resetProfileIDs.count),
                "speech_configuration_changed": String(
                    previousSpeechConfiguration != agentSpeechSettingsState.configuration),
            ])
    }

    private func recordAbortedSettingsSave(stage: String) {
        settingsError = "Settings changed while saving. Review them and save again."
        diagnostics.record(
            category: .settings,
            event: "settings.save_failed",
            level: .warning,
            fields: ["stage": stage])
    }

    private func recordSettingsSaveFailure(stage: String, error: any Error) {
        diagnostics.record(
            category: .settings,
            event: "settings.save_failed",
            level: .error,
            fields: [
                "stage": stage,
                "error_type": String(describing: type(of: error)),
            ])
    }
}

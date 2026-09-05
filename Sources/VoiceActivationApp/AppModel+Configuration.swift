// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import VoiceActivationCore

extension AppModel {
    /// Coalesces concurrent speech authorization requests into one shared task.
    func ensurePermissions() async -> Bool {
        guard !isShutdown else {
            diagnostics.record(
                category: .app,
                event: "permissions.request_ignored",
                fields: ["reason": "shutdown"])
            return false
        }
        if permissionGranted {
            diagnostics.record(
                category: .app,
                event: "permissions.cached",
                fields: ["granted": "true"])
            return true
        }
        if let permissionTask {
            diagnostics.record(category: .app, event: "permissions.joined_pending_request")
            let granted = await permissionTask.value
            return isShutdown ? false : granted
        }

        diagnostics.record(
            category: .app,
            event: "permissions.request_started",
            fields: ["task_priority": String(Task.currentPriority.rawValue)])
        let diagnostics = diagnostics
        let task = Task(priority: .userInitiated) { @MainActor [permissionRequest] in
            let startedAtUptime = DispatchTime.now().uptimeNanoseconds
            diagnostics.record(
                category: .app,
                event: "permissions.request_task_started",
                fields: ["task_priority": String(Task.currentPriority.rawValue)])
            let granted = await permissionRequest()
            let finishedAtUptime = DispatchTime.now().uptimeNanoseconds
            let duration = finishedAtUptime >= startedAtUptime
                ? (finishedAtUptime - startedAtUptime) / 1_000_000
                : 0
            diagnostics.record(
                category: .app,
                event: "permissions.request_task_finished",
                fields: [
                    "duration_ms": String(duration),
                    "granted": String(granted),
                    "task_priority": String(Task.currentPriority.rawValue),
                ])
            return granted
        }
        permissionTask = task
        let granted = await task.value
        permissionTask = nil
        guard !isShutdown else { return false }
        permissionGranted = granted
        diagnostics.record(
            category: .app,
            event: "permissions.request_finished",
            fields: [
                "granted": String(granted),
                "task_priority": String(Task.currentPriority.rawValue),
            ])
        if !permissionGranted {
            state = .failed("Microphone and Speech Recognition permissions are required.")
            passiveEnabled = false
            preferences.passiveEnabled = false
        }
        return permissionGranted
    }

    /// Returns the last applied configuration, independent of unsaved Settings drafts.
    func savedConfiguration() throws -> ActivationConfiguration {
        ActivationConfiguration(
            profiles: preferences.wakeProfiles,
            localeID: preferences.localeID)
    }

    /// Publishes the current capture state or completes an agent-panel handoff.
    func updateRecordingOverlay() {
        diagnostics.record(
            category: .ui,
            event: "recording_overlay.update_requested",
            level: .debug,
            fields: [
                "state": state.appModelDiagnosticName,
                "recognized_character_count": String(currentTranscript.count),
                "has_active_profile": String(activeProfile != nil),
            ])
        overlayPresenter.update(
            state: state,
            transcript: currentTranscript,
            accent: activeProfile?.accent ?? activeWakeProfiles.first?.accent ?? .blue)
    }

    /// Publishes one immutable conversation snapshot to UI and audio presenters.
    func publishAgentRun(_ snapshot: AgentRunSnapshot) {
        let beginsRun = agentRunSnapshot?.runID != snapshot.runID
        diagnostics.record(
            category: .ui,
            event: "agent_panel.snapshot_published",
            fields: [
                "run_id": snapshot.runID.uuidString,
                "begins_run": String(beginsRun),
                "phase": snapshot.phase.appModelDiagnosticName,
                "timeline_item_count": String(snapshot.timeline.count),
                "permission_count": String(snapshot.permissions.count),
                "notice_count": String(snapshot.notices.count),
            ])
        agentRunSnapshot = snapshot
        if beginsRun {
            agentRunPanelPresenter.begin(snapshot, from: pendingAgentHandoff)
            pendingAgentHandoff = nil
        } else {
            agentRunPanelPresenter.update(snapshot)
        }
    }

    nonisolated static func eventKind(_ event: AgentRunEvent) -> String {
        switch event {
        case .connected: "connected"
        case .agentMessageDelta: "agent_message_delta"
        case .thoughtDelta: "thought_delta"
        case .toolCall: "tool_call"
        case .toolCallUpdate: "tool_call_update"
        case .plan: "plan"
        case .permissionRequested: "permission_requested"
        case .metadata: "metadata"
        case .diagnostic: "diagnostic"
        case .deliveryNotice: "delivery_notice"
        case .unknown: "unknown"
        }
    }

    static func executableFileExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    enum SettingsValidationError: Error, LocalizedError {
        case executableIsNotRunnable(String)
        case agentExecutableIsNotRunnable(String)
        case workingDirectoryIsNotDirectory(String)
        case elevenLabsAPIKeyRequired
        case elevenLabsVoiceIDRequired

        var errorDescription: String? {
            switch self {
            case .executableIsNotRunnable(let path):
                "The executable is missing or not runnable: \(path)"
            case .agentExecutableIsNotRunnable(let path):
                "The agent executable is missing or not runnable: \(path)"
            case .workingDirectoryIsNotDirectory(let path):
                "The agent working directory is missing or is not a directory: \(path)"
            case .elevenLabsAPIKeyRequired:
                "ElevenLabs requires an API key."
            case .elevenLabsVoiceIDRequired:
                "ElevenLabs requires a voice ID."
            }
        }
    }

    enum ModelError: Error, LocalizedError {
        case unavailable

        var errorDescription: String? {
            "Voice Activation is unavailable."
        }
    }
}

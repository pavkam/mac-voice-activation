// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import VoiceActivationApp
@testable import VoiceActivationCore


extension AppModelTests {
    @MainActor
    func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        if !(await condition()) {
            Issue.record("Condition was not satisfied before timeout")
        }
    }

    @MainActor
    struct Fixture {
        let preferences: AppPreferences
        let shortcut = ShortcutSpy()
        let speech = AppModelSpeechSessionSpy()
        let agentRunPanel: AppModelAgentPanelSpy
        let model: AppModel

        init(
            profiles: [WakeProfile]? = nil,
            agentRunner: any AgentHarnessRunning = AppModelAgentRunnerSpy(),
            agentRunPanel: AppModelAgentPanelSpy = AppModelAgentPanelSpy(),
            agentConversationAudioPlayer: any AgentConversationAudioPlaying =
                SilentAgentConversationAudioPlayer(),
            agentSpeechCredentialStore: any AgentSpeechCredentialStoring =
                AgentSpeechCredentialStoreSpy(),
            elevenLabsVoiceCatalog: any ElevenLabsVoiceCatalogLoading =
                AppModelElevenLabsVoiceCatalogSpy(voices: []),
            elevenLabsVoicePreview: any ElevenLabsVoicePreviewing =
                AppModelElevenLabsVoicePreviewSpy(),
            isExecutableFile: @escaping @MainActor (String) -> Bool = { path in
                FileManager.default.isExecutableFile(atPath: path)
            },
            isDirectory: @escaping @MainActor (String) -> Bool = { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        ) throws {
            let suite = "VoiceActivationAppModelTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            preferences = AppPreferences(defaults: defaults)
            self.agentRunPanel = agentRunPanel
            if let profiles {
                preferences.wakeProfiles = profiles
            }
            model = AppModel(
                preferences: preferences,
                recordingOverlay: AppModelOverlayStub(),
                agentRunPanel: agentRunPanel,
                shortcut: shortcut,
                speechSession: speech,
                agentRunner: agentRunner,
                permissionRequest: { true },
                soundPlayer: SilentCaptureSoundPlayer(),
                agentConversationAudioPlayer: agentConversationAudioPlayer,
                agentSpeechCredentialStore: agentSpeechCredentialStore,
                elevenLabsVoiceCatalog: elevenLabsVoiceCatalog,
                elevenLabsVoicePreview: elevenLabsVoicePreview,
                isExecutableFile: isExecutableFile,
                isDirectory: isDirectory,
                startsAutomatically: false)
        }
    }

    func makeAgentProfile(
        id: UUID = UUID(),
        displayName: String = "Custom agent",
        executablePath: String = "/agents/custom",
        workingDirectory: String = "/Users/test/project",
        pushToTalkHotKey: PushToTalkHotKey? = nil
    ) throws -> WakeProfile {
        let configuration = try AgentHarnessConfiguration(
            preset: .custom,
            displayName: displayName,
            executablePath: executablePath,
            arguments: ["--stdio", "two words"],
            workingDirectory: workingDirectory,
            permissionPolicy: .ask)
        return try WakeProfile(
            id: id,
            wakePhrase: displayName,
            action: .agent(configuration),
            accent: .purple,
            pushToTalkHotKey: pushToTalkHotKey)
    }
}

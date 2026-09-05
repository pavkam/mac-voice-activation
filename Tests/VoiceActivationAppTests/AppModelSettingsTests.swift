// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import VoiceActivationApp
@testable import VoiceActivationCore


extension AppModelTests {
    @MainActor @Test func setPushToTalkHotKey_WhenRecorded_ChangesOnlyThatProfileDraft() throws {
        let fixture = try Fixture()
        let profileID = fixture.model.wakeProfiles[0].id
        let draft = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")

        fixture.model.setPushToTalkHotKey(draft, for: profileID)

        #expect(fixture.model.wakeProfiles[0].pushToTalkHotKey == draft)
        #expect(fixture.model.activeWakeProfiles[0].pushToTalkHotKey == .defaultValue)
        #expect(fixture.preferences.wakeProfiles[0].pushToTalkHotKey == .defaultValue)
        #expect(fixture.shortcut.startedProfiles.isEmpty)
    }

    @MainActor @Test func saveSettings_WhenDraftIsValid_AppliesAndPersistsHotKey() async throws {
        let fixture = try Fixture()
        let profileID = fixture.model.wakeProfiles[0].id
        let draft = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        fixture.model.setPushToTalkHotKey(draft, for: profileID)

        let saved = await fixture.model.saveSettings()

        #expect(saved)
        #expect(fixture.model.activeWakeProfiles[0].pushToTalkHotKey == draft)
        #expect(fixture.preferences.wakeProfiles[0].pushToTalkHotKey == draft)
        #expect(fixture.shortcut.startedProfiles.last?[0].pushToTalkHotKey == draft)
    }

    @MainActor @Test func saveSettings_WhenProfileIsInvalid_DoesNotApplyHotKey() async throws {
        let fixture = try Fixture()
        let profileID = fixture.model.wakeProfiles[0].id
        let draft = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        fixture.model.setPushToTalkHotKey(draft, for: profileID)
        fixture.model.wakeProfiles[0].urlTemplate = "https://example.com/static"

        let saved = await fixture.model.saveSettings()

        #expect(!saved)
        #expect(fixture.model.activeWakeProfiles[0].pushToTalkHotKey == .defaultValue)
        #expect(fixture.preferences.wakeProfiles[0].pushToTalkHotKey == .defaultValue)
        #expect(fixture.shortcut.startedProfiles.isEmpty)
    }

    @MainActor @Test func saveSettings_WhenProfilesAreValid_PersistsEveryProfile() async throws {
        let fixture = try Fixture()
        let searchHotKey = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        let assistantHotKey = try PushToTalkHotKey(
            keyCode: 45,
            modifiers: [.control, .option],
            keyLabel: "N")
        fixture.model.wakeProfiles = [
            WakeProfileDraft(
                wakePhrase: "search",
                urlTemplate: "https://search.example/?q={urlText}",
                accent: .cyan,
                pushToTalkHotKey: searchHotKey),
            WakeProfileDraft(
                wakePhrase: "ask assistant",
                urlTemplate: "https://assistant.example/?prompt={urlText}",
                accent: .purple,
                pushToTalkHotKey: assistantHotKey),
        ]

        let saved = await fixture.model.saveSettings()

        #expect(saved)
        #expect(
            fixture.preferences.wakeProfiles.map(\.wakePhrase) == [
                "search", "ask assistant",
            ])
        #expect(fixture.model.activeWakeProfiles.map(\.accent) == [.cyan, .purple])
        #expect(
            fixture.shortcut.startedProfiles.last?.map(\.pushToTalkHotKey) == [
                searchHotKey, assistantHotKey,
            ])
    }

    @MainActor @Test func saveSettings_WhenPhrasesMatchAfterNormalization_RejectsProfiles()
        async throws
    {
        let fixture = try Fixture()
        fixture.model.wakeProfiles = [
            WakeProfileDraft(
                wakePhrase: "Computer",
                urlTemplate: "https://one.example/?q={urlText}",
                accent: .blue),
            WakeProfileDraft(
                wakePhrase: "computer!",
                urlTemplate: "https://two.example/?q={urlText}",
                accent: .purple),
        ]

        let saved = await fixture.model.saveSettings()

        #expect(!saved)
        #expect(fixture.model.settingsError == "Wake phrases must be unique.")
        #expect(fixture.shortcut.startedProfiles.isEmpty)
    }

    @MainActor @Test func setWakeProfileEnabled_WhenOneProfileChanges_PersistsOnlyThatProfile()
        throws
    {
        let computer = try WakeProfile(
            wakePhrase: "computer",
            urlTemplate: "https://search.example/?q={urlText}",
            accent: .blue)
        let sneek = try WakeProfile(
            wakePhrase: "sneek",
            urlTemplate: "https://notes.example/?text={urlText}",
            accent: .purple)
        let fixture = try Fixture(profiles: [computer, sneek])

        fixture.model.setWakeProfileEnabled(sneek.id, enabled: false)

        #expect(fixture.model.activeWakeProfiles.map(\.isEnabled) == [true, false])
        #expect(fixture.model.wakeProfiles.map(\.isEnabled) == [true, false])
        #expect(fixture.preferences.wakeProfiles.map(\.isEnabled) == [true, false])
    }

    @MainActor @Test
    func saveSettings_WhenAgentExecutableIsMissing_PreservesActiveProfilesAndHotKeys() async throws
    {
        let runner = AppModelAgentRunnerSpy()
        let profile = try makeAgentProfile(
            executablePath: "/missing/agent",
            pushToTalkHotKey: .defaultValue)
        let fixture = try Fixture(
            profiles: [profile],
            agentRunner: runner,
            isExecutableFile: { _ in false },
            isDirectory: { _ in true })
        await fixture.model.start()
        let activeProfiles = fixture.model.activeWakeProfiles
        let registeredProfiles = fixture.shortcut.registeredProfiles
        let savedLocale = fixture.preferences.localeID
        fixture.model.localeID = "fr-FR"

        let saved = await fixture.model.saveSettings()

        #expect(!saved)
        #expect(fixture.model.activeWakeProfiles == activeProfiles)
        #expect(fixture.preferences.wakeProfiles == activeProfiles)
        #expect(fixture.preferences.localeID == savedLocale)
        #expect(fixture.shortcut.registeredProfiles == registeredProfiles)
        #expect(fixture.shortcut.startedProfiles == [registeredProfiles])
        #expect(await runner.recordedResets().isEmpty)
    }

    @MainActor @Test func saveSettings_WhenWorkingDirectoryIsNotDirectory_PreservesActiveProfiles()
        async throws
    {
        let runner = AppModelAgentRunnerSpy()
        let profile = try makeAgentProfile(workingDirectory: "/Users/test/not-a-directory")
        let fixture = try Fixture(
            profiles: [profile],
            agentRunner: runner,
            isExecutableFile: { _ in true },
            isDirectory: { _ in false })
        let activeProfiles = fixture.model.activeWakeProfiles

        let saved = await fixture.model.saveSettings()

        #expect(!saved)
        #expect(fixture.model.activeWakeProfiles == activeProfiles)
        #expect(fixture.preferences.wakeProfiles == activeProfiles)
        #expect(fixture.shortcut.startedProfiles.isEmpty)
        #expect(await runner.recordedResets().isEmpty)
    }

    @MainActor @Test func saveSettings_WhenCommandExecutableIsMissing_PreservesActiveProfiles()
        async throws
    {
        let runner = AppModelAgentRunnerSpy()
        let fixture = try Fixture(
            agentRunner: runner,
            isExecutableFile: { _ in false })
        let activeProfiles = fixture.model.activeWakeProfiles

        let saved = await fixture.model.saveSettings()

        #expect(!saved)
        #expect(fixture.model.activeWakeProfiles == activeProfiles)
        #expect(fixture.preferences.wakeProfiles == activeProfiles)
        #expect(fixture.shortcut.startedProfiles.isEmpty)
        #expect(await runner.recordedResets().isEmpty)
    }

    @MainActor @Test
    func saveSettings_WhenShortcutReplacementFails_RestoresExactPreviousRegistrations() async throws
    {
        let oldHotKey = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        let newHotKey = try PushToTalkHotKey(
            keyCode: 45,
            modifiers: [.control, .option],
            keyLabel: "N")
        let oldProfiles = [
            try WakeProfile(
                wakePhrase: "computer",
                urlTemplate: "https://example.com/?q={urlText}",
                accent: .blue,
                pushToTalkHotKey: oldHotKey)
        ]
        let runner = AppModelAgentRunnerSpy()
        let fixture = try Fixture(profiles: oldProfiles, agentRunner: runner)
        await fixture.model.start()
        fixture.model.setPushToTalkHotKey(newHotKey, for: oldProfiles[0].id)
        fixture.shortcut.failNextStart = true

        let saved = await fixture.model.saveSettings()

        #expect(!saved)
        #expect(fixture.shortcut.startedProfiles.count == 2)
        #expect(fixture.shortcut.startedProfiles[0] == oldProfiles)
        #expect(fixture.shortcut.startedProfiles[1][0].pushToTalkHotKey == newHotKey)
        #expect(fixture.shortcut.registeredProfiles == oldProfiles)
        #expect(fixture.model.activeWakeProfiles == oldProfiles)
        #expect(fixture.preferences.wakeProfiles == oldProfiles)
        #expect(await runner.recordedResets().isEmpty)
    }

    @MainActor @Test func saveSettings_WhenAgentProfilesChange_ResetsOnlyAffectedCachedProfiles()
        async throws
    {
        let changed = try makeAgentProfile(
            id: UUID(),
            displayName: "Changed",
            executablePath: "/agents/changed-old")
        let removed = try makeAgentProfile(
            id: UUID(),
            displayName: "Removed",
            executablePath: "/agents/removed")
        let convertedToCommand = try makeAgentProfile(
            id: UUID(),
            displayName: "Converted",
            executablePath: "/agents/converted")
        let metadataOnly = try makeAgentProfile(
            id: UUID(),
            displayName: "Metadata only",
            executablePath: "/agents/metadata")
        let convertedToAgent = try WakeProfile(
            id: UUID(),
            wakePhrase: "command",
            executablePath: "/usr/bin/open",
            argumentTemplates: ["https://example.com/?q={urlText}"],
            accent: .green)
        let runner = AppModelAgentRunnerSpy()
        let fixture = try Fixture(
            profiles: [changed, removed, convertedToCommand, metadataOnly, convertedToAgent],
            agentRunner: runner,
            isExecutableFile: { _ in true },
            isDirectory: { _ in true })

        var changedDraft = WakeProfileDraft(profile: changed)
        changedDraft.agentHarness.executablePath = "/agents/changed-new"
        var convertedCommandDraft = WakeProfileDraft(profile: convertedToCommand)
        convertedCommandDraft.targetKind = .command
        convertedCommandDraft.executablePath = "/usr/bin/open"
        convertedCommandDraft.argumentTemplates = ["https://example.com/?q={urlText}"]
        var metadataDraft = WakeProfileDraft(profile: metadataOnly)
        metadataDraft.wakePhrase = "metadata renamed"
        var convertedAgentDraft = WakeProfileDraft(profile: convertedToAgent)
        convertedAgentDraft.targetKind = .agent
        convertedAgentDraft.agentHarness = AgentHarnessDraft(
            preset: .custom,
            displayName: "New agent",
            executablePath: "/agents/new",
            arguments: [],
            workingDirectory: "/projects/new",
            permissionPolicy: .ask)
        fixture.model.wakeProfiles = [
            changedDraft,
            convertedCommandDraft,
            metadataDraft,
            convertedAgentDraft,
        ]

        let saved = await fixture.model.saveSettings()

        #expect(saved)
        #expect(
            await runner.recordedResets() == [
                [
                    changed.id,
                    removed.id,
                    convertedToCommand.id,
                ]
            ])
    }

    @MainActor @Test func coordinator_WhenAgentRunnerIsInjected_UsesSameInstanceAsSettingsReset()
        async throws
    {
        let profile = try makeAgentProfile(pushToTalkHotKey: .defaultValue)
        let runner = AppModelAgentRunnerSpy()
        let fixture = try Fixture(
            profiles: [profile],
            agentRunner: runner,
            isExecutableFile: { _ in true },
            isDirectory: { _ in true })
        await fixture.model.start()

        fixture.shortcut.press(profile.id)
        await waitUntil { fixture.speech.mode == .pushToTalk }
        fixture.speech.emit("inspect this repository")
        fixture.shortcut.release(profile.id)
        await waitUntil { await runner.recordedInvocations().count == 1 }

        let invocation = try #require(await runner.recordedInvocations().first)
        #expect(invocation.profileID == profile.id)
        #expect(invocation.prompt == "inspect this repository")

        fixture.model.wakeProfiles[0].agentHarness.executablePath = "/agents/changed"
        let saved = await fixture.model.saveSettings()

        #expect(saved)
        #expect(await runner.recordedResets() == [[profile.id]])
    }

    @MainActor @Test func pushToTalk_WhenAnotherProfileReleases_KeepsOriginalCaptureActive()
        async throws
    {
        let firstHotKey = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        let secondHotKey = try PushToTalkHotKey(
            keyCode: 45,
            modifiers: [.control, .option],
            keyLabel: "N")
        let firstProfile = try WakeProfile(
            wakePhrase: "computer",
            urlTemplate: "https://one.example/?q={urlText}",
            accent: .blue,
            pushToTalkHotKey: firstHotKey)
        let secondProfile = try WakeProfile(
            wakePhrase: "sneek",
            urlTemplate: "https://two.example/?q={urlText}",
            accent: .purple,
            pushToTalkHotKey: secondHotKey)
        let fixture = try Fixture(profiles: [firstProfile, secondProfile])
        await fixture.model.start()
        fixture.shortcut.press(firstProfile.id)
        await waitUntil { fixture.speech.mode == .pushToTalk }

        fixture.shortcut.press(secondProfile.id)
        fixture.shortcut.release(secondProfile.id)

        #expect(fixture.speech.mode == .pushToTalk)
        #expect(fixture.model.state == .capturing)
        fixture.shortcut.release(firstProfile.id)
    }

    @MainActor @Test func saveSettings_WhenSaveIsInFlight_RejectsOverlappingSave() async throws {
        let profile = try makeAgentProfile(executablePath: "/agents/original")
        let runner = AppModelAgentRunnerSpy()
        let fixture = try Fixture(
            profiles: [profile],
            agentRunner: runner,
            isExecutableFile: { _ in true },
            isDirectory: { _ in true })
        await runner.delayReset()
        fixture.model.wakeProfiles[0].agentHarness.executablePath = "/agents/changed"
        let firstSave = Task { @MainActor in await fixture.model.saveSettings() }
        await waitUntil { await runner.resetIsWaiting() }

        let overlappingSave = await fixture.model.saveSettings()

        #expect(!overlappingSave)
        #expect(fixture.model.isSavingSettings)
        await runner.releaseReset()
        #expect(await firstSave.value)
        #expect(!fixture.model.isSavingSettings)
    }

    @MainActor @Test func shortcutRecording_WhenDraftIsNotSaved_RestoresActiveHotKey() throws {
        let fixture = try Fixture()
        let profileID = fixture.model.wakeProfiles[0].id
        let draft = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        fixture.model.setPushToTalkHotKey(draft, for: profileID)

        fixture.model.setPushToTalkShortcutRecording(true)
        fixture.model.setPushToTalkShortcutRecording(false)

        #expect(fixture.shortcut.stopCount == 1)
        #expect(fixture.shortcut.startedProfiles.last?[0].pushToTalkHotKey == .defaultValue)
        #expect(fixture.preferences.wakeProfiles[0].pushToTalkHotKey == .defaultValue)
    }

}

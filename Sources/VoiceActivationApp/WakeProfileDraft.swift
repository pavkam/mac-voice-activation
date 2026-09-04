// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import VoiceActivationCore

enum WakeProfileTargetKind: String, CaseIterable {
    case command
    case agent
}

struct WakeProfileDraft: Equatable, Identifiable {
    var id: UUID
    var wakePhrase: String
    var executablePath: String
    var commandArguments: ArgumentDraftCollection
    var agentHarness: AgentHarnessDraft
    var targetKind: WakeProfileTargetKind
    var accent: WakeProfileAccent
    var isEnabled: Bool
    var pushToTalkHotKey: PushToTalkHotKey?

    var argumentTemplates: [String] {
        get { commandArguments.values }
        set { commandArguments.replace(with: newValue) }
    }

    var urlTemplate: String {
        get { commandArguments.rows.first?.value ?? "" }
        set {
            if commandArguments.rows.isEmpty {
                commandArguments = ArgumentDraftCollection(values: [newValue])
            } else {
                commandArguments.rows[0].value = newValue
            }
        }
    }

    init(
        id: UUID = UUID(),
        wakePhrase: String,
        urlTemplate: String,
        accent: WakeProfileAccent,
        isEnabled: Bool = true,
        pushToTalkHotKey: PushToTalkHotKey? = nil)
    {
        self.id = id
        self.wakePhrase = wakePhrase
        executablePath = "/usr/bin/open"
        commandArguments = ArgumentDraftCollection(values: [urlTemplate])
        agentHarness = .empty(
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        targetKind = .command
        self.accent = accent
        self.isEnabled = isEnabled
        self.pushToTalkHotKey = pushToTalkHotKey
    }

    init(
        id: UUID = UUID(),
        wakePhrase: String,
        executablePath: String,
        argumentTemplates: [String],
        agentHarness: AgentHarnessDraft,
        targetKind: WakeProfileTargetKind,
        accent: WakeProfileAccent,
        isEnabled: Bool = true,
        pushToTalkHotKey: PushToTalkHotKey? = nil)
    {
        self.id = id
        self.wakePhrase = wakePhrase
        self.executablePath = executablePath
        commandArguments = ArgumentDraftCollection(values: argumentTemplates)
        self.agentHarness = agentHarness
        self.targetKind = targetKind
        self.accent = accent
        self.isEnabled = isEnabled
        self.pushToTalkHotKey = pushToTalkHotKey
    }

    init(profile: WakeProfile) {
        id = profile.id
        wakePhrase = profile.wakePhrase
        accent = profile.accent
        isEnabled = profile.isEnabled
        pushToTalkHotKey = profile.pushToTalkHotKey
        switch profile.action {
        case let .command(command):
            executablePath = command.executablePath
            commandArguments = ArgumentDraftCollection(values: command.argumentTemplates)
            agentHarness = .empty(
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            targetKind = .command
        case let .agent(configuration):
            executablePath = "/usr/bin/open"
            commandArguments = ArgumentDraftCollection(
                values: ["https://www.google.com/search?q={urlText}"])
            agentHarness = AgentHarnessDraft(configuration: configuration)
            targetKind = .agent
        }
    }

    mutating func selectTarget(
        _ target: WakeProfileTargetKind,
        locator: AgentExecutableLocator = AgentExecutableLocator())
    {
        targetKind = target
        guard target == .agent else { return }
        agentHarness.selectDefaultPresetIfAvailable(locator: locator)
    }

    func validatedProfile() throws -> WakeProfile {
        let action: WakeProfileAction
        switch targetKind {
        case .command:
            action = .command(try CommandTemplate(
                executablePath: executablePath,
                argumentTemplates: argumentTemplates))
            guard argumentTemplates.contains(where: {
                $0.contains("{text}") || $0.contains("{urlText}")
            }) else {
                throw WakeProfile.ValidationError.missingTranscriptPlaceholder
            }
        case .agent:
            action = .agent(try agentHarness.validatedConfiguration())
        }
        return try WakeProfile(
            id: id,
            wakePhrase: wakePhrase,
            action: action,
            accent: accent,
            isEnabled: isEnabled,
            pushToTalkHotKey: pushToTalkHotKey)
    }
}

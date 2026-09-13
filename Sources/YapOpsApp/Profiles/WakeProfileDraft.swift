// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import YapOpsCore

enum WakeProfileTargetKind: String, CaseIterable {
    case command
    case systemAction
    case agent

    /// The segmented-control label for this target.
    var title: String {
        switch self {
        case .command: "Command"
        case .systemAction: "System action"
        case .agent: "Agent"
        }
    }
}

struct WakeProfileDraft: Equatable, Identifiable {
    var id: UUID
    var name: String
    var icon: ProfileIcon
    var wakePhrase: String
    var executablePath: String
    var commandArguments: ArgumentDraftCollection
    var agentHarness: AgentHarnessDraft
    var systemActions: SystemActionSetDraft
    var targetKind: WakeProfileTargetKind
    var accent: WakeProfileAccent
    var isEnabled: Bool
    var pushToTalkHotKey: PushToTalkHotKey?
    var speechPreference: ProfileSpeechPreference

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
        name: String? = nil,
        icon: ProfileIcon = .defaultValue,
        wakePhrase: String,
        urlTemplate: String,
        accent: WakeProfileAccent,
        isEnabled: Bool = true,
        pushToTalkHotKey: PushToTalkHotKey? = nil,
        speechPreference: ProfileSpeechPreference = .inherit)
    {
        self.id = id
        self.name = name ?? Self.defaultName(for: wakePhrase)
        self.icon = icon
        self.wakePhrase = wakePhrase
        executablePath = "/usr/bin/open"
        commandArguments = ArgumentDraftCollection(values: [urlTemplate])
        agentHarness = .empty(
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        systemActions = .defaultValue
        targetKind = .command
        self.accent = accent
        self.isEnabled = isEnabled
        self.pushToTalkHotKey = pushToTalkHotKey
        self.speechPreference = speechPreference
    }

    init(
        id: UUID = UUID(),
        name: String? = nil,
        icon: ProfileIcon = .defaultValue,
        wakePhrase: String,
        executablePath: String,
        argumentTemplates: [String],
        agentHarness: AgentHarnessDraft,
        systemActions: SystemActionSetDraft = .defaultValue,
        targetKind: WakeProfileTargetKind,
        accent: WakeProfileAccent,
        isEnabled: Bool = true,
        pushToTalkHotKey: PushToTalkHotKey? = nil,
        speechPreference: ProfileSpeechPreference = .inherit)
    {
        self.id = id
        self.name = name ?? Self.defaultName(for: wakePhrase)
        self.icon = icon
        self.wakePhrase = wakePhrase
        self.executablePath = executablePath
        commandArguments = ArgumentDraftCollection(values: argumentTemplates)
        self.agentHarness = agentHarness
        self.systemActions = systemActions
        self.targetKind = targetKind
        self.accent = accent
        self.isEnabled = isEnabled
        self.pushToTalkHotKey = pushToTalkHotKey
        self.speechPreference = speechPreference
    }

    init(profile: WakeProfile) {
        id = profile.id
        name = profile.name
        icon = profile.icon
        wakePhrase = profile.wakePhrase
        accent = profile.accent
        isEnabled = profile.isEnabled
        pushToTalkHotKey = profile.pushToTalkHotKey
        speechPreference = profile.speechPreference
        switch profile.action {
        case let .command(command):
            executablePath = command.executablePath
            commandArguments = ArgumentDraftCollection(values: command.argumentTemplates)
            agentHarness = .empty(
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            systemActions = .defaultValue
            targetKind = .command
        case let .agent(configuration):
            executablePath = "/usr/bin/open"
            commandArguments = ArgumentDraftCollection(
                values: ["https://www.google.com/search?q={urlText}"])
            agentHarness = AgentHarnessDraft(configuration: configuration)
            systemActions = .defaultValue
            targetKind = .agent
        case let .systemAction(set):
            executablePath = "/usr/bin/open"
            commandArguments = ArgumentDraftCollection(
                values: ["https://www.google.com/search?q={urlText}"])
            agentHarness = .empty(
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            systemActions = SystemActionSetDraft(set: set)
            targetKind = .systemAction
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
        case .systemAction:
            action = .systemAction(try systemActions.validatedSet())
        case .agent:
            action = .agent(try agentHarness.validatedConfiguration())
        }
        return try WakeProfile(
            id: id,
            name: name,
            icon: icon,
            wakePhrase: wakePhrase,
            action: action,
            accent: accent,
            isEnabled: isEnabled,
            pushToTalkHotKey: pushToTalkHotKey,
            speechPreference: speechPreference)
    }

    private static func defaultName(for wakePhrase: String) -> String {
        let value = wakePhrase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.isEmpty ? "New Profile" : value.capitalized
    }
}

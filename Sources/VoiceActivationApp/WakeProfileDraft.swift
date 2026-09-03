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
    var argumentTemplates: [String]
    var agentHarness: AgentHarnessDraft
    var targetKind: WakeProfileTargetKind
    var accent: WakeProfileAccent
    var isEnabled: Bool
    var pushToTalkHotKey: PushToTalkHotKey?

    var urlTemplate: String {
        get { argumentTemplates.first ?? "" }
        set {
            if argumentTemplates.isEmpty {
                argumentTemplates = [newValue]
            } else {
                argumentTemplates[0] = newValue
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
        argumentTemplates = [urlTemplate]
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
        self.argumentTemplates = argumentTemplates
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
            argumentTemplates = command.argumentTemplates
            agentHarness = .empty(
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            targetKind = .command
        case let .agent(configuration):
            executablePath = "/usr/bin/open"
            argumentTemplates = ["https://www.google.com/search?q={urlText}"]
            agentHarness = AgentHarnessDraft(configuration: configuration)
            targetKind = .agent
        }
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

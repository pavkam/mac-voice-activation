import Foundation
import VoiceActivationCore

struct WakeProfileDraft: Equatable, Identifiable {
    var id: UUID
    var wakePhrase: String
    var urlTemplate: String
    var accent: WakeProfileAccent
    var isEnabled: Bool
    var pushToTalkHotKey: PushToTalkHotKey?

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
        self.urlTemplate = urlTemplate
        self.accent = accent
        self.isEnabled = isEnabled
        self.pushToTalkHotKey = pushToTalkHotKey
    }

    init(profile: WakeProfile) {
        id = profile.id
        wakePhrase = profile.wakePhrase
        urlTemplate = profile.argumentTemplates.first ?? ""
        accent = profile.accent
        isEnabled = profile.isEnabled
        pushToTalkHotKey = profile.pushToTalkHotKey
    }

    func validatedProfile() throws -> WakeProfile {
        try WakeProfile(
            id: id,
            wakePhrase: wakePhrase,
            urlTemplate: urlTemplate,
            accent: accent,
            isEnabled: isEnabled,
            pushToTalkHotKey: pushToTalkHotKey)
    }
}

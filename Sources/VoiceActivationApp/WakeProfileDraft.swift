import Foundation
import VoiceActivationCore

struct WakeProfileDraft: Equatable, Identifiable {
    var id: UUID
    var wakePhrase: String
    var urlTemplate: String
    var accent: WakeProfileAccent
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        wakePhrase: String,
        urlTemplate: String,
        accent: WakeProfileAccent,
        isEnabled: Bool = true)
    {
        self.id = id
        self.wakePhrase = wakePhrase
        self.urlTemplate = urlTemplate
        self.accent = accent
        self.isEnabled = isEnabled
    }

    init(profile: WakeProfile) {
        id = profile.id
        wakePhrase = profile.wakePhrase
        urlTemplate = profile.argumentTemplates.first ?? ""
        accent = profile.accent
        isEnabled = profile.isEnabled
    }

    func validatedProfile() throws -> WakeProfile {
        try WakeProfile(
            id: id,
            wakePhrase: wakePhrase,
            urlTemplate: urlTemplate,
            accent: accent,
            isEnabled: isEnabled)
    }
}

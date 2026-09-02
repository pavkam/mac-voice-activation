import Foundation
import VoiceActivationCore

struct WakeProfileDraft: Equatable, Identifiable {
    var id: UUID
    var wakePhrase: String
    var urlTemplate: String
    var accent: WakeProfileAccent

    init(
        id: UUID = UUID(),
        wakePhrase: String,
        urlTemplate: String,
        accent: WakeProfileAccent)
    {
        self.id = id
        self.wakePhrase = wakePhrase
        self.urlTemplate = urlTemplate
        self.accent = accent
    }

    init(profile: WakeProfile) {
        id = profile.id
        wakePhrase = profile.wakePhrase
        urlTemplate = profile.argumentTemplates.first ?? ""
        accent = profile.accent
    }

    func validatedProfile() throws -> WakeProfile {
        try WakeProfile(
            id: id,
            wakePhrase: wakePhrase,
            urlTemplate: urlTemplate,
            accent: accent)
    }
}

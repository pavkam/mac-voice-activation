import Testing
@testable import VoiceActivationCore

struct WakeProfileCollectionValidatorTests {
    @Test func validate_WhenWakePhrasesDifferOnlyByMatchingNormalization_RejectsThem() throws {
        let profiles = [
            try WakeProfile(
                wakePhrase: "Computer",
                urlTemplate: "https://one.example/?q={urlText}",
                accent: .blue),
            try WakeProfile(
                wakePhrase: "computer!",
                urlTemplate: "https://two.example/?q={urlText}",
                accent: .purple),
        ]

        #expect(throws: WakeProfileCollectionValidationError.duplicateWakePhrase) {
            try WakeProfileCollectionValidator.validate(profiles)
        }
    }

    @Test func validate_WhenPushToTalkBindingsRepeat_RejectsThem() throws {
        let hotKey = try PushToTalkHotKey(
            keyCode: 49,
            modifiers: [.control, .option],
            keyLabel: "Space")
        let profiles = [
            try WakeProfile(
                wakePhrase: "computer",
                urlTemplate: "https://one.example/?q={urlText}",
                accent: .blue,
                pushToTalkHotKey: hotKey),
            try WakeProfile(
                wakePhrase: "sneek",
                urlTemplate: "https://two.example/?q={urlText}",
                accent: .purple,
                pushToTalkHotKey: hotKey),
        ]

        #expect(throws: WakeProfileCollectionValidationError.duplicatePushToTalkHotKey) {
            try WakeProfileCollectionValidator.validate(profiles)
        }
    }

    @Test func validate_WhenPushToTalkBindingsSharePhysicalKeyWithDifferentLabels_RejectsThem() throws {
        let firstHotKey = try PushToTalkHotKey(
            keyCode: 49,
            modifiers: [.control, .option],
            keyLabel: "Space")
        let secondHotKey = try PushToTalkHotKey(
            keyCode: 49,
            modifiers: [.control, .option],
            keyLabel: "Spacebar")
        let profiles = [
            try WakeProfile(
                wakePhrase: "computer",
                urlTemplate: "https://one.example/?q={urlText}",
                accent: .blue,
                pushToTalkHotKey: firstHotKey),
            try WakeProfile(
                wakePhrase: "sneek",
                urlTemplate: "https://two.example/?q={urlText}",
                accent: .purple,
                pushToTalkHotKey: secondHotKey),
        ]

        #expect(throws: WakeProfileCollectionValidationError.duplicatePushToTalkHotKey) {
            try WakeProfileCollectionValidator.validate(profiles)
        }
    }

    @Test func validate_WhenCollectionIsEmpty_RejectsIt() {
        #expect(throws: WakeProfileCollectionValidationError.profileRequired) {
            try WakeProfileCollectionValidator.validate([])
        }
    }

    @Test func validate_WhenProfilesDoNotConflict_AcceptsThem() throws {
        let profiles = [
            try WakeProfile(
                wakePhrase: "computer",
                urlTemplate: "https://one.example/?q={urlText}",
                accent: .blue),
            try WakeProfile(
                wakePhrase: "sneek",
                urlTemplate: "https://two.example/?q={urlText}",
                accent: .purple),
        ]

        try WakeProfileCollectionValidator.validate(profiles)
    }
}

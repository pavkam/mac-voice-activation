import Foundation
import Observation
import VoiceActivationCore

@MainActor
@Observable
final class AppModel {
    var state: ActivationState = .disabled
    var lastTranscript = ""
    var currentTranscript = ""
    var passiveEnabled: Bool
    var wakeProfiles: [WakeProfileDraft]
    private(set) var activeWakeProfiles: [WakeProfile]
    var localeID: String
    var settingsError: String?

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let speechSession: AppleSpeechSession
    @ObservationIgnored private let shortcut: any PushToTalkShortcutManaging
    @ObservationIgnored private let overlayPresenter: RecordingOverlayPresenter
    @ObservationIgnored private let soundPresenter: CaptureSoundPresenter
    @ObservationIgnored private var started = false
    @ObservationIgnored private var permissionGranted = false
    @ObservationIgnored private var hotkeyHeld = false
    @ObservationIgnored private var recordingShortcut = false
    @ObservationIgnored private var activeProfile: WakeProfile?
    @ObservationIgnored private lazy var coordinator = VoiceActivationCoordinator(
        speechSession: speechSession,
        commandRunner: CommandRunner(),
        configuration: { [weak self] in
            guard let self else { throw ModelError.unavailable }
            return try self.savedConfiguration()
        })

    init(
        preferences: AppPreferences = AppPreferences(),
        recordingOverlay: any RecordingOverlayDisplaying = RecordingOverlayController(),
        shortcut: any PushToTalkShortcutManaging = PushToTalkShortcut(),
        soundPlayer: any CaptureSoundPlaying = SystemCaptureSoundPlayer(),
        startsAutomatically: Bool = true)
    {
        self.preferences = preferences
        self.shortcut = shortcut
        speechSession = AppleSpeechSession()
        overlayPresenter = RecordingOverlayPresenter(display: recordingOverlay)
        soundPresenter = CaptureSoundPresenter(player: soundPlayer)
        passiveEnabled = preferences.passiveEnabled
        activeWakeProfiles = preferences.wakeProfiles
        wakeProfiles = preferences.wakeProfiles.map(WakeProfileDraft.init)
        localeID = preferences.localeID
        overlayPresenter.onCancel = { [weak self] in
            self?.cancelCapture()
        }

        if startsAutomatically {
            Task { @MainActor [weak self] in
                await self?.start()
            }
        }
    }

    func setPassiveEnabled(_ enabled: Bool) {
        passiveEnabled = enabled
        preferences.passiveEnabled = enabled
        if enabled {
            Task { @MainActor [weak self] in
                guard let self, await self.ensurePermissions() else { return }
                self.coordinator.setPassiveEnabled(true)
            }
        } else {
            coordinator.setPassiveEnabled(false)
        }
    }

    func setWakeProfileEnabled(_ id: UUID, enabled: Bool) {
        guard let activeIndex = activeWakeProfiles.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard activeWakeProfiles[activeIndex].isEnabled != enabled else { return }

        activeWakeProfiles[activeIndex].isEnabled = enabled
        preferences.wakeProfiles = activeWakeProfiles
        if let draftIndex = wakeProfiles.firstIndex(where: { $0.id == id }) {
            wakeProfiles[draftIndex].isEnabled = enabled
        }
        coordinator.refreshConfiguration()
    }

    @discardableResult
    func saveSettings() -> Bool {
        let profiles: [WakeProfile]
        do {
            guard !wakeProfiles.isEmpty else { throw ModelError.profileRequired }
            profiles = try wakeProfiles.map { try $0.validatedProfile() }
            let phrases = profiles.map { $0.wakePhrase.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current) }
            guard Set(phrases).count == phrases.count else {
                throw ModelError.duplicateWakePhrase
            }
            let hotKeys = profiles.compactMap(\.pushToTalkHotKey)
            guard Set(hotKeys).count == hotKeys.count else {
                throw ModelError.duplicatePushToTalkHotKey
            }
        } catch {
            settingsError = error.localizedDescription
            return false
        }

        do {
            try registerShortcuts(profiles)
        } catch {
            try? registerShortcuts(activeWakeProfiles)
            settingsError = error.localizedDescription
            return false
        }

        preferences.wakeProfiles = profiles
        preferences.localeID = localeID
        activeWakeProfiles = preferences.wakeProfiles
        wakeProfiles = activeWakeProfiles.map(WakeProfileDraft.init)
        localeID = preferences.localeID
        settingsError = nil
        coordinator.refreshConfiguration()
        return true
    }

    func shutdown() {
        shortcut.stop()
        coordinator.stop()
        overlayPresenter.update(state: .disabled, transcript: "")
    }

    func setPushToTalkHotKey(_ hotKey: PushToTalkHotKey?, for profileID: UUID) {
        guard let index = wakeProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        guard wakeProfiles[index].pushToTalkHotKey != hotKey else { return }
        wakeProfiles[index].pushToTalkHotKey = hotKey
        settingsError = nil
    }

    func setPushToTalkShortcutRecording(_ recording: Bool) {
        guard recording != recordingShortcut else { return }
        recordingShortcut = recording
        if recording {
            shortcut.stop()
            return
        }

        do {
            try registerShortcuts(activeWakeProfiles)
        } catch {
            settingsError = error.localizedDescription
        }
    }

    private func start() async {
        guard !started else { return }
        started = true
        coordinator.onStateChange = { [weak self] in
            self?.state = $0
            self?.soundPresenter.update(state: $0)
            self?.updateRecordingOverlay()
        }
        coordinator.onTranscriptChange = { [weak self] in self?.lastTranscript = $0 }
        coordinator.onCurrentTranscriptChange = { [weak self] in
            self?.currentTranscript = $0
            self?.updateRecordingOverlay()
        }
        coordinator.onActiveProfileChange = { [weak self] in
            self?.activeProfile = $0
            self?.updateRecordingOverlay()
        }
        do {
            try registerShortcuts(activeWakeProfiles)
        } catch {
            settingsError = error.localizedDescription
        }

        if passiveEnabled, await ensurePermissions() {
            coordinator.setPassiveEnabled(true)
        }
    }

    private func registerShortcuts(_ profiles: [WakeProfile]) throws {
        try shortcut.start(
            profiles: profiles,
            onPressed: { [weak self] in self?.pushToTalkPressed(profileID: $0) },
            onReleased: { [weak self] _ in self?.pushToTalkReleased() })
    }

    private func pushToTalkPressed(profileID: UUID) {
        guard !hotkeyHeld else { return }
        hotkeyHeld = true
        Task { @MainActor [weak self] in
            guard let self, await self.ensurePermissions(), self.hotkeyHeld else { return }
            self.coordinator.pushToTalkPressed(profileID: profileID)
        }
    }

    private func pushToTalkReleased() {
        guard hotkeyHeld else { return }
        hotkeyHeld = false
        coordinator.pushToTalkReleased()
    }

    func cancelCapture() {
        hotkeyHeld = false
        coordinator.cancelCapture()
    }

    private func ensurePermissions() async -> Bool {
        if permissionGranted { return true }
        permissionGranted = await SpeechPermissions.request()
        if !permissionGranted {
            state = .failed("Microphone and Speech Recognition permissions are required.")
            passiveEnabled = false
            preferences.passiveEnabled = false
        }
        return permissionGranted
    }

    private func savedConfiguration() throws -> ActivationConfiguration {
        ActivationConfiguration(
            profiles: preferences.wakeProfiles,
            localeID: preferences.localeID)
    }

    private func updateRecordingOverlay() {
        overlayPresenter.update(
            state: state,
            transcript: currentTranscript,
            accent: activeProfile?.accent ?? activeWakeProfiles.first?.accent ?? .blue)
    }

    private enum ModelError: Error, LocalizedError {
        case unavailable
        case profileRequired
        case duplicateWakePhrase
        case duplicatePushToTalkHotKey

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "Voice Activation is unavailable."
            case .profileRequired:
                "Add at least one wake profile."
            case .duplicateWakePhrase:
                "Wake phrases must be unique."
            case .duplicatePushToTalkHotKey:
                "Push-to-talk shortcuts must be unique."
            }
        }
    }
}

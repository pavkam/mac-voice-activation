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
    var wakePhrase: String
    var localeID: String
    var pushToTalkHotKey: PushToTalkHotKey
    var executablePath: String
    var argumentTemplatesText: String
    var settingsError: String?

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let speechSession: AppleSpeechSession
    @ObservationIgnored private let shortcut = PushToTalkShortcut()
    @ObservationIgnored private let overlayPresenter: RecordingOverlayPresenter
    @ObservationIgnored private var started = false
    @ObservationIgnored private var permissionGranted = false
    @ObservationIgnored private var hotkeyHeld = false
    @ObservationIgnored private var recordingShortcut = false
    @ObservationIgnored private lazy var coordinator = VoiceActivationCoordinator(
        speechSession: speechSession,
        commandRunner: CommandRunner(),
        configuration: { [weak self] in
            guard let self else { throw ModelError.unavailable }
            return try self.savedConfiguration()
        })

    init(
        preferences: AppPreferences = AppPreferences(),
        recordingOverlay: any RecordingOverlayDisplaying = RecordingOverlayController())
    {
        self.preferences = preferences
        speechSession = AppleSpeechSession()
        overlayPresenter = RecordingOverlayPresenter(display: recordingOverlay)
        passiveEnabled = preferences.passiveEnabled
        wakePhrase = preferences.wakePhrase
        localeID = preferences.localeID
        pushToTalkHotKey = preferences.pushToTalkHotKey
        executablePath = preferences.executablePath
        argumentTemplatesText = preferences.argumentTemplates.joined(separator: "\n")
        overlayPresenter.onCancel = { [weak self] in
            self?.cancelCapture()
        }

        Task { @MainActor [weak self] in
            await self?.start()
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

    @discardableResult
    func saveSettings() -> Bool {
        let arguments = parsedArgumentTemplates()
        do {
            _ = try CommandTemplate(
                executablePath: executablePath.trimmingCharacters(in: .whitespacesAndNewlines),
                argumentTemplates: arguments)
        } catch {
            settingsError = error.localizedDescription
            return false
        }

        preferences.wakePhrase = wakePhrase
        preferences.localeID = localeID
        preferences.executablePath = executablePath
        preferences.argumentTemplates = arguments
        wakePhrase = preferences.wakePhrase
        localeID = preferences.localeID
        executablePath = preferences.executablePath
        argumentTemplatesText = arguments.joined(separator: "\n")
        settingsError = nil
        coordinator.refreshConfiguration()
        return true
    }

    func shutdown() {
        shortcut.stop()
        coordinator.stop()
        overlayPresenter.update(state: .disabled, transcript: "")
    }

    func setPushToTalkHotKey(_ hotKey: PushToTalkHotKey) {
        guard hotKey != pushToTalkHotKey else { return }
        let previousHotKey = pushToTalkHotKey
        if hotkeyHeld {
            hotkeyHeld = false
            coordinator.cancelCapture()
        }

        do {
            try registerShortcut(hotKey)
        } catch {
            try? registerShortcut(previousHotKey)
            settingsError = error.localizedDescription
            return
        }

        pushToTalkHotKey = hotKey
        preferences.pushToTalkHotKey = hotKey
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
            try registerShortcut(pushToTalkHotKey)
        } catch {
            settingsError = error.localizedDescription
        }
    }

    private func start() async {
        guard !started else { return }
        started = true
        coordinator.onStateChange = { [weak self] in
            self?.state = $0
            self?.updateRecordingOverlay()
        }
        coordinator.onTranscriptChange = { [weak self] in self?.lastTranscript = $0 }
        coordinator.onCurrentTranscriptChange = { [weak self] in
            self?.currentTranscript = $0
            self?.updateRecordingOverlay()
        }
        do {
            try registerShortcut(pushToTalkHotKey)
        } catch {
            settingsError = error.localizedDescription
        }

        if passiveEnabled, await ensurePermissions() {
            coordinator.setPassiveEnabled(true)
        }
    }

    private func registerShortcut(_ hotKey: PushToTalkHotKey) throws {
        try shortcut.start(
            hotKey: hotKey,
            onPressed: { [weak self] in self?.pushToTalkPressed() },
            onReleased: { [weak self] in self?.pushToTalkReleased() })
    }

    private func pushToTalkPressed() {
        guard !hotkeyHeld else { return }
        hotkeyHeld = true
        Task { @MainActor [weak self] in
            guard let self, await self.ensurePermissions(), self.hotkeyHeld else { return }
            self.coordinator.pushToTalkPressed()
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
            wakePhrase: preferences.wakePhrase,
            localeID: preferences.localeID,
            commandTemplate: try CommandTemplate(
                executablePath: preferences.executablePath,
                argumentTemplates: preferences.argumentTemplates))
    }

    private func parsedArgumentTemplates() -> [String] {
        argumentTemplatesText
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
    }

    private func updateRecordingOverlay() {
        overlayPresenter.update(state: state, transcript: currentTranscript)
    }

    private enum ModelError: Error {
        case unavailable
    }
}

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
    private(set) var isSavingSettings = false
    private(set) var agentRunSnapshot: AgentRunSnapshot?

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let speechSession: any SpeechSessionProtocol
    @ObservationIgnored private let commandRunner: any CommandRunning
    @ObservationIgnored private let agentRunner: any AgentHarnessRunning
    @ObservationIgnored private let isExecutableFile: @MainActor (String) -> Bool
    @ObservationIgnored private let isDirectory: @MainActor (String) -> Bool
    @ObservationIgnored private let permissionRequest: @MainActor () async -> Bool
    @ObservationIgnored private let shortcut: any PushToTalkShortcutManaging
    @ObservationIgnored private let overlayPresenter: RecordingOverlayPresenter
    @ObservationIgnored private let agentRunPresentation: AgentRunPresentation
    @ObservationIgnored private let agentRunPanelPresenter: AgentRunPanelPresenter
    @ObservationIgnored private let soundPresenter: CaptureSoundPresenter
    @ObservationIgnored private var started = false
    @ObservationIgnored private var permissionGranted = false
    @ObservationIgnored private var permissionTask: Task<Bool, Never>?
    @ObservationIgnored private var hotkeyHeld = false
    @ObservationIgnored private var recordingShortcut = false
    @ObservationIgnored private var activeProfile: WakeProfile?
    @ObservationIgnored private var pendingAgentHandoff: RecordingOverlayHandoff?
    @ObservationIgnored private lazy var coordinator = VoiceActivationCoordinator(
        speechSession: speechSession,
        commandRunner: commandRunner,
        agentRunner: agentRunner,
        configuration: { [weak self] in
            guard let self else { throw ModelError.unavailable }
            return try self.savedConfiguration()
        })

    init(
        preferences: AppPreferences = AppPreferences(),
        recordingOverlay: any RecordingOverlayDisplaying = RecordingOverlayController(),
        agentRunPanel: any AgentRunPanelDisplaying = AgentRunPanelController(),
        shortcut: any PushToTalkShortcutManaging = PushToTalkShortcut(),
        speechSession: any SpeechSessionProtocol = AppleSpeechSession(),
        commandRunner: any CommandRunning = CommandRunner(),
        agentRunner: any AgentHarnessRunning = ACPAgentRunner(),
        permissionRequest: @escaping @MainActor () async -> Bool = SpeechPermissions.request,
        soundPlayer: any CaptureSoundPlaying = SystemCaptureSoundPlayer(),
        isExecutableFile: @escaping @MainActor (String) -> Bool = AppModel.executableFileExists,
        isDirectory: @escaping @MainActor (String) -> Bool = AppModel.directoryExists,
        startsAutomatically: Bool = true)
    {
        self.preferences = preferences
        self.shortcut = shortcut
        self.speechSession = speechSession
        self.commandRunner = commandRunner
        self.agentRunner = agentRunner
        self.isExecutableFile = isExecutableFile
        self.isDirectory = isDirectory
        self.permissionRequest = permissionRequest
        overlayPresenter = RecordingOverlayPresenter(display: recordingOverlay)
        agentRunPresentation = AgentRunPresentation()
        agentRunPanelPresenter = AgentRunPanelPresenter(display: agentRunPanel)
        soundPresenter = CaptureSoundPresenter(player: soundPlayer)
        passiveEnabled = preferences.passiveEnabled
        activeWakeProfiles = preferences.wakeProfiles
        wakeProfiles = preferences.wakeProfiles.map(WakeProfileDraft.init)
        localeID = preferences.localeID
        overlayPresenter.onCancel = { [weak self] in
            self?.cancelCapture()
        }
        agentRunPresentation.onPublication = { [weak self] snapshot in
            self?.publishAgentRun(snapshot)
        }
        agentRunPanelPresenter.onCancel = { [weak self] runID in
            self?.cancelAgentRun(runID: runID)
        }
        agentRunPanelPresenter.onPermission = { [weak self] runID, key, optionID in
            self?.resolveAgentPermission(
                runID: runID,
                key: key,
                optionID: optionID)
        }
        agentRunPanelPresenter.onClose = { [weak self] runID in
            self?.agentRunPresentation.close(runID: runID)
        }

        if startsAutomatically {
            Task { @MainActor [weak self] in
                await self?.start()
            }
        }
    }

    func setPassiveEnabled(_ enabled: Bool) {
        guard passiveEnabled != enabled else { return }
        passiveEnabled = enabled
        preferences.passiveEnabled = enabled
        if enabled {
            Task { @MainActor [weak self] in
                guard let self, self.passiveEnabled else { return }
                let permissionGranted = await self.ensurePermissions()
                guard self.passiveEnabled else {
                    self.state = .disabled
                    return
                }
                guard permissionGranted else { return }
                self.coordinator.setPassiveEnabled(true)
            }
        } else {
            coordinator.setPassiveEnabled(false)
        }
    }

    func togglePassiveListening() {
        setPassiveEnabled(!passiveEnabled)
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
    func saveSettings() async -> Bool {
        guard !isSavingSettings else { return false }
        isSavingSettings = true
        defer { isSavingSettings = false }

        let profiles: [WakeProfile]
        do {
            profiles = try wakeProfiles.map { try $0.validatedProfile() }
            try WakeProfileCollectionValidator.validate(profiles)
            try validateFileSystem(profiles)
        } catch {
            settingsError = error.localizedDescription
            return false
        }

        do {
            try registerShortcuts(profiles)
        } catch {
            settingsError = error.localizedDescription
            return false
        }

        let profileIDsToReset = agentProfileIDsToReset(
            oldProfiles: activeWakeProfiles,
            newProfiles: profiles)
        preferences.wakeProfiles = profiles
        preferences.localeID = localeID
        activeWakeProfiles = profiles
        wakeProfiles = activeWakeProfiles.map(WakeProfileDraft.init)
        localeID = preferences.localeID
        if !profileIDsToReset.isEmpty {
            await agentRunner.reset(profileIDs: profileIDsToReset)
        }
        settingsError = nil
        coordinator.refreshConfiguration()
        return true
    }

    func shutdown() {
        shortcut.stop()
        coordinator.stop()
        overlayPresenter.update(state: .disabled, transcript: "")
        if let runID = agentRunSnapshot?.runID {
            agentRunPanelPresenter.hide(runID: runID)
        }
        agentRunPresentation.shutdown()
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

    func start() async {
        guard !started else { return }
        started = true
        coordinator.onStateChange = { [weak self] in
            guard let self else { return }
            if $0 == .capturing {
                self.pendingAgentHandoff = nil
            } else if $0 == .executing, self.pendingAgentHandoff == nil {
                self.pendingAgentHandoff = self.overlayPresenter.takeAgentRunHandoff()
            } else if $0 != .executing {
                self.pendingAgentHandoff = nil
            }
            self.state = $0
            self.soundPresenter.update(state: $0)
            self.updateRecordingOverlay()
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
        coordinator.onAgentRunEvent = { [weak self] event in
            self?.handleAgentRunLifecycleEvent(event)
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

    private func validateFileSystem(_ profiles: [WakeProfile]) throws {
        for profile in profiles {
            switch profile.action {
            case let .command(command):
                guard isExecutableFile(command.executablePath) else {
                    throw SettingsValidationError.executableIsNotRunnable(
                        command.executablePath)
                }
            case let .agent(configuration):
                guard isExecutableFile(configuration.executablePath) else {
                    throw SettingsValidationError.agentExecutableIsNotRunnable(
                        configuration.executablePath)
                }
                guard isDirectory(configuration.workingDirectory) else {
                    throw SettingsValidationError.workingDirectoryIsNotDirectory(
                        configuration.workingDirectory)
                }
            }
        }
    }

    private func agentProfileIDsToReset(
        oldProfiles: [WakeProfile],
        newProfiles: [WakeProfile]) -> Set<UUID>
    {
        let newProfilesByID = Dictionary(uniqueKeysWithValues: newProfiles.map { ($0.id, $0) })
        return Set(oldProfiles.compactMap { oldProfile in
            guard case let .agent(oldConfiguration) = oldProfile.action else { return nil }
            guard let newProfile = newProfilesByID[oldProfile.id] else { return oldProfile.id }
            switch newProfile.action {
            case .command:
                return oldProfile.id
            case let .agent(newConfiguration):
                return oldConfiguration == newConfiguration ? nil : oldProfile.id
            }
        })
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

    func showAgentRun() {
        guard let runID = agentRunSnapshot?.runID else { return }
        agentRunPanelPresenter.show(runID: runID)
    }

    func cancelAgentRun(runID: UUID) {
        guard agentRunPresentation.beginCancellation(runID: runID) else { return }
        coordinator.cancelAgentRun()
    }

    func resolveAgentPermission(
        runID: UUID,
        key: AgentPermissionKey,
        optionID: String)
    {
        guard agentRunPresentation.beginPermissionResolution(runID: runID, key: key) else {
            return
        }
        coordinator.resolveAgentPermission(
            runID: runID,
            turnToken: key.turnToken,
            requestID: key.requestID,
            optionID: optionID)
    }

    func handleAgentRunLifecycleEvent(_ event: AgentRunLifecycleEvent) {
        switch event {
        case let .started(runID, profile, prompt):
            agentRunPresentation.start(runID: runID, profile: profile, prompt: prompt)
        case let .event(runID, event):
            agentRunPresentation.receive(runID: runID, event: event)
        case let .completed(runID, result):
            agentRunPresentation.complete(runID: runID, result: result)
        case let .failed(runID, message):
            agentRunPresentation.fail(runID: runID, message: message)
        }
    }

    private func ensurePermissions() async -> Bool {
        if permissionGranted { return true }
        if let permissionTask {
            return await permissionTask.value
        }

        let task = Task { @MainActor [permissionRequest] in
            await permissionRequest()
        }
        permissionTask = task
        permissionGranted = await task.value
        permissionTask = nil
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

    private func publishAgentRun(_ snapshot: AgentRunSnapshot) {
        let beginsRun = agentRunSnapshot?.runID != snapshot.runID
        agentRunSnapshot = snapshot
        if beginsRun {
            agentRunPanelPresenter.begin(snapshot, from: pendingAgentHandoff)
            pendingAgentHandoff = nil
        } else {
            agentRunPanelPresenter.update(snapshot)
        }
    }

    private static func executableFileExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    private static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private enum SettingsValidationError: Error, LocalizedError {
        case executableIsNotRunnable(String)
        case agentExecutableIsNotRunnable(String)
        case workingDirectoryIsNotDirectory(String)

        var errorDescription: String? {
            switch self {
            case let .executableIsNotRunnable(path):
                "The executable is missing or not runnable: \(path)"
            case let .agentExecutableIsNotRunnable(path):
                "The agent executable is missing or not runnable: \(path)"
            case let .workingDirectoryIsNotDirectory(path):
                "The agent working directory is missing or is not a directory: \(path)"
            }
        }
    }

    private enum ModelError: Error, LocalizedError {
        case unavailable

        var errorDescription: String? {
            "Voice Activation is unavailable."
        }
    }
}

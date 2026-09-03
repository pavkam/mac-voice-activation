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
    var readsAgentRepliesAloud: Bool
    var playsAgentWorkingSound: Bool
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
    @ObservationIgnored private let agentConversationAudioPlayer: any AgentConversationAudioPlaying
    @ObservationIgnored private let agentConversationAudioPresenter: AgentConversationAudioPresenter
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isShutdown = false
    @ObservationIgnored private var permissionGranted = false
    @ObservationIgnored private var permissionTask: Task<Bool, Never>?
    @ObservationIgnored private var heldHotKeyProfileID: UUID?
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
        agentConversationAudioPlayer: any AgentConversationAudioPlaying =
            SystemAgentConversationAudioPlayer(),
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
        self.agentConversationAudioPlayer = agentConversationAudioPlayer
        agentConversationAudioPresenter = AgentConversationAudioPresenter(
            player: agentConversationAudioPlayer,
            readsReplies: { preferences.readsAgentRepliesAloud },
            playsWorkingSound: { preferences.playsAgentWorkingSound },
            localeID: { preferences.localeID })
        passiveEnabled = preferences.passiveEnabled
        activeWakeProfiles = preferences.wakeProfiles
        wakeProfiles = preferences.wakeProfiles.map(WakeProfileDraft.init)
        localeID = preferences.localeID
        readsAgentRepliesAloud = preferences.readsAgentRepliesAloud
        playsAgentWorkingSound = preferences.playsAgentWorkingSound
        overlayPresenter.onCancel = { [weak self] in
            self?.cancelCapture()
        }
        agentRunPresentation.onPublication = { [weak self] snapshot in
            self?.publishAgentRun(snapshot)
        }
        agentRunPanelPresenter.onCancel = { [weak self] runID in
            self?.cancelAgentRun(runID: runID)
        }
        agentRunPanelPresenter.onEndConversation = { [weak self] runID in
            self?.endAgentConversation(runID: runID)
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
        agentConversationAudioPlayer.onSpeakingChange = { [weak self] speaking in
            self?.coordinator.setAgentSpeechOutputActive(speaking)
        }

        if startsAutomatically {
            Task { @MainActor [weak self] in
                await self?.start()
            }
        }
    }

    func setPassiveEnabled(_ enabled: Bool) {
        guard !isShutdown else { return }
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
        preferences.readsAgentRepliesAloud = readsAgentRepliesAloud
        preferences.playsAgentWorkingSound = playsAgentWorkingSound
        agentConversationAudioPresenter.refreshSettings()
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
        guard !isShutdown else { return }
        isShutdown = true
        heldHotKeyProfileID = nil
        shortcut.stop()
        coordinator.stop()
        overlayPresenter.update(state: .disabled, transcript: "")
        if let runID = agentRunSnapshot?.runID {
            agentRunPanelPresenter.hide(runID: runID)
        }
        agentRunPresentation.shutdown()
        agentConversationAudioPresenter.shutdown()
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
        guard !started, !isShutdown else { return }
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
            guard let self else { return }
            self.currentTranscript = $0
            if let snapshot = self.agentRunSnapshot, !snapshot.phase.isTerminal {
                self.agentRunPresentation.updateVoiceInput(
                    runID: snapshot.runID,
                    transcript: $0)
            }
            self.updateRecordingOverlay()
        }
        coordinator.onActiveProfileChange = { [weak self] in
            self?.activeProfile = $0
            self?.updateRecordingOverlay()
        }
        coordinator.onAgentRunEvent = { [weak self] event in
            self?.handleAgentRunLifecycleEvent(event)
        }
        coordinator.onAgentSpeechCancellation = { [weak self] in
            self?.agentConversationAudioPlayer.stopSpeaking()
        }
        do {
            try registerShortcuts(activeWakeProfiles)
        } catch {
            settingsError = error.localizedDescription
        }

        guard passiveEnabled else { return }
        guard await ensurePermissions(), passiveEnabled, !isShutdown else { return }
        coordinator.setPassiveEnabled(true)
    }

    private func registerShortcuts(_ profiles: [WakeProfile]) throws {
        try shortcut.start(
            profiles: profiles,
            onPressed: { [weak self] in self?.pushToTalkPressed(profileID: $0) },
            onReleased: { [weak self] in self?.pushToTalkReleased(profileID: $0) })
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
        guard !isShutdown, heldHotKeyProfileID == nil else { return }
        heldHotKeyProfileID = profileID
        Task { @MainActor [weak self] in
            guard let self,
                  await self.ensurePermissions(),
                  self.heldHotKeyProfileID == profileID
            else { return }
            self.coordinator.pushToTalkPressed(profileID: profileID)
        }
    }

    private func pushToTalkReleased(profileID: UUID) {
        guard heldHotKeyProfileID == profileID else { return }
        heldHotKeyProfileID = nil
        coordinator.pushToTalkReleased()
    }

    func cancelCapture() {
        heldHotKeyProfileID = nil
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

    func endAgentConversation(runID: UUID) {
        guard agentRunSnapshot?.runID == runID,
              agentRunSnapshot?.phase.isTerminal == false
        else { return }
        coordinator.endAgentConversation()
    }

    func resolveAgentPermission(
        runID: UUID,
        key: AgentPermissionKey,
        optionID: String)
    {
        guard agentRunPresentation.beginPermissionResolution(runID: runID, key: key) else {
            return
        }
        agentConversationAudioPresenter.resumeAfterPermission(runID: runID)
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
        case let .followUpSubmitted(runID, prompt):
            agentRunPresentation.submitFollowUp(runID: runID, prompt: prompt)
        case let .notice(runID, message):
            agentRunPresentation.receiveNotice(runID: runID, message: message)
        case let .turnStarted(runID):
            agentRunPresentation.beginTurn(runID: runID)
        case let .turnCancellationStarted(runID):
            _ = agentRunPresentation.beginCancellation(runID: runID)
        case let .event(runID, event):
            agentRunPresentation.receive(runID: runID, event: event)
        case let .turnCompleted(runID, result):
            agentRunPresentation.completeTurn(runID: runID, result: result)
        case let .completed(runID, result):
            agentRunPresentation.complete(runID: runID, result: result)
        case let .failed(runID, message):
            agentRunPresentation.fail(runID: runID, message: message)
        }
        agentConversationAudioPresenter.handle(event)
    }

    private func ensurePermissions() async -> Bool {
        guard !isShutdown else { return false }
        if permissionGranted { return true }
        if let permissionTask {
            let granted = await permissionTask.value
            return isShutdown ? false : granted
        }

        let task = Task { @MainActor [permissionRequest] in
            await permissionRequest()
        }
        permissionTask = task
        let granted = await task.value
        permissionTask = nil
        guard !isShutdown else { return false }
        permissionGranted = granted
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

import Foundation
import Testing
@testable import VoiceActivationCore

@MainActor
private final class FakeSpeechSession: SpeechSessionProtocol {
    private(set) var mode: SpeechSessionMode?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var contextualStrings: [String] = []
    private var handler: ((SpeechUpdate) -> Void)?
    private var interruptionHandler: (() -> Void)?
    private var retiredHandlers: [(SpeechUpdate) -> Void] = []
    private var failingMode: SpeechSessionMode?

    func start(
        mode: SpeechSessionMode,
        localeID: String,
        contextualStrings: [String],
        onUpdate: @escaping (SpeechUpdate) -> Void,
        onInterruption: @escaping () -> Void) throws
    {
        if failingMode == mode {
            failingMode = nil
            throw FakeSpeechSessionError.startFailed
        }
        startCount += 1
        self.mode = mode
        self.contextualStrings = contextualStrings
        handler = onUpdate
        interruptionHandler = onInterruption
    }

    func stop() {
        stopCount += 1
        mode = nil
        if let handler {
            retiredHandlers.append(handler)
        }
        handler = nil
        interruptionHandler = nil
    }

    func emit(_ transcript: String, isFinal: Bool = false) {
        handler?(SpeechUpdate(transcript: transcript, isFinal: isFinal, errorDescription: nil))
    }

    func emitError(_ description: String) {
        handler?(SpeechUpdate(transcript: "", isFinal: false, errorDescription: description))
    }

    func interrupt() {
        interruptionHandler?()
    }

    func emitFromRetiredSession(_ transcript: String, isFinal: Bool = false) {
        retiredHandlers.last?(
            SpeechUpdate(transcript: transcript, isFinal: isFinal, errorDescription: nil))
    }

    func failNextStart(for mode: SpeechSessionMode) {
        failingMode = mode
    }
}

private enum FakeSpeechSessionError: Error {
    case startFailed
}

private actor RecordingCommandRunner: CommandRunning {
    private(set) var transcripts: [String] = []
    private(set) var templates: [CommandTemplate] = []

    func run(template: CommandTemplate, transcript: String) async throws -> CommandResult {
        templates.append(template)
        transcripts.append(transcript)
        return CommandResult(terminationStatus: 0)
    }

    func recordedTranscripts() -> [String] {
        transcripts
    }

    func recordedTemplates() -> [CommandTemplate] {
        templates
    }
}

private actor ControlledCommandRunner: CommandRunning {
    private var transcripts: [String] = []
    private var continuations: [CheckedContinuation<CommandResult, Never>] = []

    func run(template: CommandTemplate, transcript: String) async throws -> CommandResult {
        transcripts.append(transcript)
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func recordedTranscripts() -> [String] {
        transcripts
    }

    func completeNext() {
        continuations.removeFirst().resume(returning: CommandResult(terminationStatus: 0))
    }
}

private actor ControlledAgentRunner: AgentHarnessRunning {
    struct Invocation: Equatable, Sendable {
        let profileID: UUID
        let configuration: AgentHarnessConfiguration
        let prompt: String
    }

    struct PermissionResolution: Equatable, Sendable {
        let turnToken: AgentTurnToken
        let requestID: ACPRequestID
        let optionID: String?
    }

    private(set) var cancelCount = 0
    private(set) var shutdownCount = 0
    private var invocations: [Invocation] = []
    private var permissionResolutions: [PermissionResolution] = []
    private var eventHandlers: [@Sendable (AgentRunEvent) async -> Void] = []
    private var completions: [CheckedContinuation<AgentRunResult, any Error>?] = []
    private var activeRunIndex: Int?

    func run(
        profileID: UUID,
        configuration: AgentHarnessConfiguration,
        prompt: String,
        onEvent: @escaping @Sendable (AgentRunEvent) async -> Void
    ) async throws -> AgentRunResult {
        guard activeRunIndex == nil else {
            throw ControlledAgentRunnerError.turnAlreadyActive
        }

        let runIndex = invocations.count
        invocations.append(Invocation(
            profileID: profileID,
            configuration: configuration,
            prompt: prompt))
        eventHandlers.append(onEvent)
        activeRunIndex = runIndex
        return try await withCheckedThrowingContinuation { continuation in
            completions.append(continuation)
        }
    }

    func resolvePermission(
        turnToken: AgentTurnToken,
        requestID: ACPRequestID,
        optionID: String?) async
    {
        permissionResolutions.append(PermissionResolution(
            turnToken: turnToken,
            requestID: requestID,
            optionID: optionID))
    }

    func cancel() async {
        cancelCount += 1
        activeRunIndex = nil
    }

    func reset(profileIDs: Set<UUID>) async {}

    func shutdown() async {
        shutdownCount += 1
        activeRunIndex = nil
    }

    func recordedInvocations() -> [Invocation] {
        invocations
    }

    func recordedPermissionResolutions() -> [PermissionResolution] {
        permissionResolutions
    }

    func emit(_ event: AgentRunEvent, from runIndex: Int) async {
        await eventHandlers[runIndex](event)
    }

    func complete(
        runIndex: Int,
        stopReason: AgentStopReason = .endTurn)
    {
        let continuation = completions[runIndex]
        completions[runIndex] = nil
        if activeRunIndex == runIndex {
            activeRunIndex = nil
        }
        continuation?.resume(returning: AgentRunResult(stopReason: stopReason))
    }

    func fail(runIndex: Int, error: any Error) {
        let continuation = completions[runIndex]
        completions[runIndex] = nil
        if activeRunIndex == runIndex {
            activeRunIndex = nil
        }
        continuation?.resume(throwing: error)
    }
}

private enum ControlledAgentRunnerError: Error, LocalizedError {
    case turnAlreadyActive
    case runFailed

    var errorDescription: String? {
        switch self {
        case .turnAlreadyActive:
            "Another fake agent turn is already active."
        case .runFailed:
            "The fake agent run failed."
        }
    }
}

private func makeAgentConfiguration(
    displayName: String = "Codex",
    workingDirectory: String = "/tmp") throws -> AgentHarnessConfiguration
{
    try AgentHarnessConfiguration(
        preset: .codex,
        displayName: displayName,
        executablePath: "/usr/bin/env",
        arguments: ["agent"],
        workingDirectory: workingDirectory,
        permissionPolicy: .ask)
}

private func makeAgentProfile(
    id: UUID = UUID(),
    wakePhrase: String = "agent",
    displayName: String = "Codex",
    accent: WakeProfileAccent = .purple) throws -> WakeProfile
{
    try WakeProfile(
        id: id,
        wakePhrase: wakePhrase,
        action: .agent(try makeAgentConfiguration(displayName: displayName)),
        accent: accent)
}

@Suite(.serialized)
struct VoiceActivationCoordinatorTests {
    @MainActor @Test func setPassiveEnabled_WhenProfilesConfigured_BiasesWakeRecognition() throws {
        let profiles = [
            try WakeProfile(
                wakePhrase: "computer",
                urlTemplate: "https://example.com?q={urlText}",
                accent: .blue),
            try WakeProfile(
                wakePhrase: "sneek",
                urlTemplate: "https://example.com/note?q={urlText}",
                accent: .purple),
        ]
        let fixture = try Fixture(profiles: profiles)

        fixture.coordinator.setPassiveEnabled(true)

        #expect(fixture.speech.contextualStrings == ["computer", "sneek"])
    }

    @MainActor @Test func setPassiveEnabled_WhenProfileIsDisabled_ExcludesItFromRecognition() throws {
        let profiles = [
            try WakeProfile(
                wakePhrase: "computer",
                urlTemplate: "https://example.com?q={urlText}",
                accent: .blue),
            try WakeProfile(
                wakePhrase: "sneek",
                urlTemplate: "https://example.com/note?q={urlText}",
                accent: .purple,
                isEnabled: false),
        ]
        let fixture = try Fixture(profiles: profiles)

        fixture.coordinator.setPassiveEnabled(true)

        #expect(fixture.speech.contextualStrings == ["computer"])
    }

    @MainActor @Test func setPassiveEnabled_WhenEveryProfileIsDisabled_DoesNotUseMicrophone() throws {
        let profile = try WakeProfile(
            wakePhrase: "computer",
            urlTemplate: "https://example.com?q={urlText}",
            accent: .blue,
            isEnabled: false)
        let fixture = try Fixture(profiles: [profile])

        fixture.coordinator.setPassiveEnabled(true)

        #expect(fixture.coordinator.state == .disabled)
        #expect(fixture.speech.startCount == 0)
        #expect(fixture.speech.mode == nil)
    }

    @MainActor @Test func passiveUpdate_WhenProfileMatches_UsesItsURLAndAccent() async throws {
        let search = try WakeProfile(
            wakePhrase: "search",
            urlTemplate: "https://search.example/?q={urlText}",
            accent: .cyan)
        let ask = try WakeProfile(
            wakePhrase: "ask assistant",
            urlTemplate: "https://assistant.example/new?prompt={urlText}",
            accent: .purple)
        let fixture = try Fixture(profiles: [search, ask])
        var activeProfiles: [WakeProfile?] = []
        fixture.coordinator.onActiveProfileChange = { activeProfiles.append($0) }
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("ask assistant summarize this", isFinal: true)
        await waitUntil {
            await fixture.runner.recordedTranscripts() == ["summarize this"]
        }

        let templates = await fixture.runner.recordedTemplates()
        #expect(templates.first?.argumentTemplates == [
            "https://assistant.example/new?prompt={urlText}",
        ])
        #expect(activeProfiles.contains(ask))
    }

    @MainActor @Test func setPassiveEnabled_WhenEnabled_StartsPassiveListening() throws {
        let fixture = try Fixture()

        fixture.coordinator.setPassiveEnabled(true)

        #expect(fixture.coordinator.state == .listening)
        #expect(fixture.speech.mode == .passiveWake)
    }

    @MainActor @Test func passiveSession_WhenAudioInputChanges_RebuildsListeningSession() async throws {
        let fixture = try Fixture(timing: .fast)
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.interrupt()
        await waitUntil {
            fixture.speech.startCount == 2
                && fixture.speech.mode == .passiveWake
                && fixture.coordinator.state == .listening
        }

        #expect(fixture.coordinator.currentTranscript.isEmpty)
        #expect(await fixture.runner.recordedTranscripts().isEmpty)
    }

    @MainActor @Test func passiveUpdate_WhenWakeAndCommandAreFinal_ExecutesCommandAndResumes() async throws {
        let fixture = try Fixture()
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("computer open calendar", isFinal: true)
        await waitUntil {
            await fixture.runner.recordedTranscripts() == ["open calendar"]
                && fixture.coordinator.state == .listening
        }

        #expect(fixture.coordinator.lastTranscript == "open calendar")
        #expect(fixture.coordinator.state == .listening)
        #expect(fixture.speech.mode == .passiveWake)
    }

    @MainActor @Test func passiveUpdate_WhenFinalCommandIsCancellationWord_CancelsCapture() async throws {
        let fixture = try Fixture()
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("computer cancel", isFinal: true)

        #expect(fixture.coordinator.state == .listening)
        #expect(fixture.coordinator.currentTranscript.isEmpty)
        #expect(fixture.speech.mode == .passiveWake)
        #expect(await fixture.runner.recordedTranscripts().isEmpty)
    }

    @MainActor @Test func passiveUpdate_WhenWakePhraseFinalizesAlone_KeepsCapturing() throws {
        let fixture = try Fixture()
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("computer", isFinal: true)

        #expect(fixture.coordinator.state == .capturing)
        #expect(fixture.speech.mode == .commandCapture)
    }

    @MainActor @Test func passiveUpdate_WhenWakePhraseIsPartialAlone_CapturesCommandAfterPause() async throws {
        let fixture = try Fixture(timing: .wakeHandoff)
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("computer")

        #expect(fixture.coordinator.state == .capturing)
        await waitUntil(timeout: .milliseconds(200)) {
            fixture.speech.mode == .commandCapture
        }

        fixture.speech.emit("open calendar", isFinal: true)
        await waitUntil {
            await fixture.runner.recordedTranscripts() == ["open calendar"]
        }

        #expect(fixture.coordinator.lastTranscript == "open calendar")
    }

    @MainActor @Test func passiveUpdate_WhenCommandImmediatelyFollowsPartialWake_ExecutesOnlyCommand() async throws {
        let fixture = try Fixture()
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("computer")
        fixture.speech.emit("computer open calendar", isFinal: true)
        await waitUntil {
            await fixture.runner.recordedTranscripts() == ["open calendar"]
        }

        #expect(fixture.coordinator.lastTranscript == "open calendar")
    }

    @MainActor @Test func passiveUpdate_WhenPartialWakeIsRevised_CancelsPendingHandoff() async throws {
        let fixture = try Fixture(timing: .wakeHandoff)
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("computer")
        fixture.speech.emit("completely different")
        try await Task.sleep(for: .milliseconds(50))

        #expect(fixture.coordinator.state == .listening)
        #expect(fixture.speech.mode == .passiveWake)
        #expect(await fixture.runner.recordedTranscripts().isEmpty)
    }

    @MainActor @Test func passiveUpdate_WhenCommandIsPartial_PublishesLiveCommandText() throws {
        let fixture = try Fixture()
        var publishedTranscripts: [String] = []
        fixture.coordinator.onCurrentTranscriptChange = {
            publishedTranscripts.append($0)
        }
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("computer open cal")

        #expect(fixture.coordinator.currentTranscript == "open cal")
        #expect(publishedTranscripts.last == "open cal")
    }

    @MainActor @Test func passiveUpdate_WhenCommandFollowsFinalWake_ExecutesCommand() async throws {
        let fixture = try Fixture()
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("computer", isFinal: true)
        fixture.speech.emit("open calendar", isFinal: true)
        await waitUntil {
            await fixture.runner.recordedTranscripts() == ["open calendar"]
        }

        #expect(fixture.coordinator.lastTranscript == "open calendar")
    }

    @MainActor @Test func commandCapture_WhenRecognitionFails_ResumesPassiveListening() async throws {
        let fixture = try Fixture(timing: .fast)
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("computer", isFinal: true)

        fixture.speech.emitError("recognizer ended")
        await waitUntil {
            fixture.coordinator.state == .listening
        }

        #expect(fixture.speech.mode == .passiveWake)
    }

    @MainActor @Test func commandCapture_WhenSessionCannotStart_ResumesPassiveListening() async throws {
        let fixture = try Fixture(timing: .startFailure)
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.failNextStart(for: .commandCapture)

        fixture.speech.emit("computer", isFinal: true)
        await waitUntil(timeout: .milliseconds(200)) {
            fixture.coordinator.state == .listening
                && fixture.speech.mode == .passiveWake
        }

        #expect(await fixture.runner.recordedTranscripts().isEmpty)
    }

    @MainActor @Test func commandCapture_WhenNoSpeechArrives_ReturnsToPassiveAfterMaximum() async throws {
        let fixture = try Fixture(timing: .fast)
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("computer", isFinal: true)
        await waitUntil {
            fixture.coordinator.state == .listening
                && fixture.speech.mode == .passiveWake
        }

        #expect(await fixture.runner.recordedTranscripts().isEmpty)
    }

    @MainActor @Test func commandCapture_WhenNoWordsArrive_ReturnsToPassiveAfterInitialSilence() async throws {
        let fixture = try Fixture(timing: .initialSilence)
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("computer", isFinal: true)
        await waitUntil(timeout: .milliseconds(200)) {
            fixture.coordinator.state == .listening
                && fixture.speech.mode == .passiveWake
        }

        #expect(await fixture.runner.recordedTranscripts().isEmpty)
    }

    @MainActor @Test func commandCapture_WhenEmptyFinalsRepeat_DoesNotResetMaximum() async throws {
        let fixture = try Fixture(timing: .repeatingEmptyFinals)
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("computer", isFinal: true)

        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(10))
            fixture.speech.emit("", isFinal: true)
        }

        #expect(fixture.coordinator.state == .listening)
        #expect(fixture.speech.mode == .passiveWake)
        #expect(await fixture.runner.recordedTranscripts().isEmpty)
    }

    @MainActor @Test func commandCapture_WhenWordsArrive_CancelsInitialSilence() async throws {
        let fixture = try Fixture(timing: .initialSilenceThenInactivity)
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("computer", isFinal: true)

        try await Task.sleep(for: .milliseconds(10))
        fixture.speech.emit("open calendar")
        try await Task.sleep(for: .milliseconds(100))

        #expect(fixture.coordinator.state == .capturing)
        #expect(await fixture.runner.recordedTranscripts().isEmpty)
        await waitUntil(timeout: .milliseconds(200)) {
            await fixture.runner.recordedTranscripts() == ["open calendar"]
        }
    }

    @MainActor @Test func commandCapture_WhenPartialCommandGoesQuiet_ExecutesAfterInactivity() async throws {
        let fixture = try Fixture(timing: .fast)
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("computer", isFinal: true)

        fixture.speech.emit("open calendar")
        await waitUntil {
            await fixture.runner.recordedTranscripts() == ["open calendar"]
        }

        #expect(fixture.coordinator.lastTranscript == "open calendar")
    }

    @MainActor @Test func commandCapture_WhenCancellationWordRepeatsInPartial_CancelsImmediately() async throws {
        let fixture = try Fixture()
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("computer", isFinal: true)

        fixture.speech.emit("cancel cancel")

        #expect(fixture.coordinator.state == .listening)
        #expect(fixture.speech.mode == .passiveWake)
        #expect(await fixture.runner.recordedTranscripts().isEmpty)
    }

    @MainActor @Test func commandCapture_WhenFinalCommandIsCancellationWord_CancelsCapture() async throws {
        let fixture = try Fixture()
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("computer", isFinal: true)

        fixture.speech.emit("stop", isFinal: true)

        #expect(fixture.coordinator.state == .listening)
        #expect(fixture.speech.mode == .passiveWake)
        #expect(await fixture.runner.recordedTranscripts().isEmpty)
    }

    @MainActor @Test func commandCapture_WhenPartialStopBecomesNormalCommand_ExecutesCommand() async throws {
        let fixture = try Fixture()
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("computer", isFinal: true)

        fixture.speech.emit("stop")
        #expect(fixture.coordinator.state == .capturing)
        fixture.speech.emit("stop the music", isFinal: true)
        await waitUntil {
            await fixture.runner.recordedTranscripts() == ["stop the music"]
        }

        #expect(fixture.coordinator.lastTranscript == "stop the music")
    }

    @MainActor @Test func commandCapture_WhenRetiredWakeSessionUpdates_IgnoresStaleTranscript() async throws {
        let fixture = try Fixture()
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("computer", isFinal: true)

        fixture.speech.emitFromRetiredSession("computer stale command", isFinal: true)
        try await Task.sleep(for: .milliseconds(30))

        #expect(fixture.coordinator.state == .capturing)
        #expect(fixture.coordinator.lastTranscript.isEmpty)
        #expect(await fixture.runner.recordedTranscripts().isEmpty)
    }

    @MainActor @Test func pushToTalk_WhenPressed_PreemptsPassiveAndReleaseExecutesSpeech() async throws {
        let fixture = try Fixture()
        fixture.coordinator.setPassiveEnabled(true)

        fixture.coordinator.pushToTalkPressed()
        #expect(fixture.speech.mode == .pushToTalk)
        fixture.speech.emit("show deployments")
        fixture.coordinator.pushToTalkReleased()
        await waitUntil {
            await fixture.runner.recordedTranscripts() == ["show deployments"]
                && fixture.coordinator.state == .listening
        }

        #expect(fixture.coordinator.lastTranscript == "show deployments")
        #expect(fixture.speech.mode == .passiveWake)
    }

    @MainActor @Test func pushToTalk_WhenProfileBindingIsPressed_UsesThatProfilesCommand() async throws {
        let computer = try WakeProfile(
            wakePhrase: "computer",
            urlTemplate: "https://wake.example/?q={urlText}",
            accent: .blue)
        let sneek = try WakeProfile(
            wakePhrase: "sneek",
            urlTemplate: "https://notes.example/?q={urlText}",
            accent: .purple)
        let fixture = try Fixture(profiles: [computer, sneek])

        fixture.coordinator.pushToTalkPressed(profileID: sneek.id)
        fixture.speech.emit("keyboard command")
        fixture.coordinator.pushToTalkReleased()
        await waitUntil {
            await fixture.runner.recordedTranscripts() == ["keyboard command"]
        }

        #expect(await fixture.runner.recordedTemplates().first?.argumentTemplates == [
            "https://notes.example/?q={urlText}",
        ])
    }

    @MainActor @Test func pushToTalk_WhenProfileBindingIsPressed_PublishesProfileBeforeCapture() throws {
        let computer = try WakeProfile(
            wakePhrase: "computer",
            urlTemplate: "https://wake.example/?q={urlText}",
            accent: .blue)
        let sneek = try WakeProfile(
            wakePhrase: "sneek",
            urlTemplate: "https://notes.example/?q={urlText}",
            accent: .purple)
        let fixture = try Fixture(profiles: [computer, sneek])
        var profileWhenCaptureBegan: WakeProfile?
        fixture.coordinator.onStateChange = { state in
            if state == .capturing {
                profileWhenCaptureBegan = fixture.coordinator.activeProfile
            }
        }

        fixture.coordinator.pushToTalkPressed(profileID: sneek.id)

        #expect(profileWhenCaptureBegan == sneek)
    }

    @MainActor @Test func pushToTalk_WhenCommandIsPartial_PublishesLiveText() throws {
        let fixture = try Fixture()

        fixture.coordinator.pushToTalkPressed()
        fixture.speech.emit("show deploy")

        #expect(fixture.coordinator.currentTranscript == "show deploy")
    }

    @MainActor @Test func pushToTalk_WhenReleased_ClearsLiveText() throws {
        let fixture = try Fixture()
        fixture.coordinator.pushToTalkPressed()
        fixture.speech.emit("show deploy")

        fixture.coordinator.pushToTalkReleased()

        #expect(fixture.coordinator.currentTranscript.isEmpty)
    }

    @MainActor @Test func cancelCapture_WhenWakeCaptureIsActive_DiscardsCommandAndResumes() async throws {
        let fixture = try Fixture()
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("computer open calendar")

        fixture.coordinator.cancelCapture()
        try await Task.sleep(for: .milliseconds(20))

        #expect(fixture.coordinator.state == .listening)
        #expect(fixture.coordinator.currentTranscript.isEmpty)
        #expect(fixture.speech.mode == .passiveWake)
        #expect(await fixture.runner.recordedTranscripts().isEmpty)
    }

    @MainActor @Test func cancelCapture_WhenPushToTalkIsActive_DiscardsCommandAndResumes() async throws {
        let fixture = try Fixture()
        fixture.coordinator.setPassiveEnabled(true)
        fixture.coordinator.pushToTalkPressed()
        fixture.speech.emit("open calendar")

        fixture.coordinator.cancelCapture()
        fixture.coordinator.pushToTalkReleased()
        try await Task.sleep(for: .milliseconds(20))

        #expect(fixture.coordinator.state == .listening)
        #expect(fixture.coordinator.currentTranscript.isEmpty)
        #expect(fixture.speech.mode == .passiveWake)
        #expect(await fixture.runner.recordedTranscripts().isEmpty)
    }

    @MainActor @Test func pushToTalk_WhenTranscriptIsEmpty_DoesNotExecuteAndResumes() async throws {
        let fixture = try Fixture()
        fixture.coordinator.setPassiveEnabled(true)

        fixture.coordinator.pushToTalkPressed()
        fixture.coordinator.pushToTalkReleased()
        try await Task.sleep(for: .milliseconds(20))

        #expect(await fixture.runner.recordedTranscripts().isEmpty)
        #expect(fixture.coordinator.state == .listening)
        #expect(fixture.speech.mode == .passiveWake)
    }

    @MainActor @Test func pushToTalk_WhenReleasedWithCancellationWord_CancelsCapture() async throws {
        let fixture = try Fixture()
        fixture.coordinator.setPassiveEnabled(true)
        fixture.coordinator.pushToTalkPressed()
        fixture.speech.emit("dismiss")

        fixture.coordinator.pushToTalkReleased()

        #expect(fixture.coordinator.state == .listening)
        #expect(fixture.speech.mode == .passiveWake)
        #expect(await fixture.runner.recordedTranscripts().isEmpty)
    }

    @MainActor @Test func pushToTalk_WhenCancellationWordRepeats_CancelsBeforeRelease() async throws {
        let fixture = try Fixture()
        fixture.coordinator.setPassiveEnabled(true)
        fixture.coordinator.pushToTalkPressed()

        fixture.speech.emit("stop stop")

        #expect(fixture.coordinator.state == .listening)
        #expect(fixture.speech.mode == .passiveWake)
        #expect(await fixture.runner.recordedTranscripts().isEmpty)
    }

    @MainActor
    @Test func execution_WhenProfileUsesAgent_RoutesTranscriptAndPublishesEventsInOrder() async throws {
        let commandProfile = try WakeProfile(
            wakePhrase: "computer",
            urlTemplate: "https://example.com/?q={urlText}",
            accent: .blue)
        let agentProfile = try makeAgentProfile()
        let fixture = try Fixture(profiles: [commandProfile, agentProfile])
        var lifecycleEvents: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { lifecycleEvents.append($0) }
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("agent inspect the parser", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }
        await fixture.agentRunner.emit(
            .connected(agentName: "Codex", sessionID: "session-1"),
            from: 0)
        await fixture.agentRunner.emit(
            .agentMessageDelta(messageID: "message-1", text: "Checking"),
            from: 0)

        #expect(await fixture.runner.recordedTranscripts().isEmpty)
        #expect(await fixture.agentRunner.recordedInvocations() == [
            ControlledAgentRunner.Invocation(
                profileID: agentProfile.id,
                configuration: try makeAgentConfiguration(),
                prompt: "inspect the parser"),
        ])
        guard case let .started(runID, startedProfile, prompt) = lifecycleEvents.first else {
            Issue.record("Expected an agent run start")
            return
        }
        #expect(startedProfile == agentProfile)
        #expect(prompt == "inspect the parser")
        #expect(Array(lifecycleEvents.dropFirst()) == [
            .event(
                runID: runID,
                event: .connected(agentName: "Codex", sessionID: "session-1")),
            .event(
                runID: runID,
                event: .agentMessageDelta(messageID: "message-1", text: "Checking")),
        ])

        await fixture.agentRunner.complete(runIndex: 0)
        await waitUntil {
            lifecycleEvents.last == .completed(
                runID: runID,
                result: AgentRunResult(stopReason: .endTurn))
                && fixture.coordinator.state == .listening
        }
    }

    @MainActor @Test func resolveAgentPermission_WhenRunIsCurrent_ForwardsExactTuple() async throws {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        var lifecycleEvents: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { lifecycleEvents.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent request access", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }
        guard case let .started(runID, _, _) = lifecycleEvents.first else {
            Issue.record("Expected an agent run start")
            return
        }
        let turnToken = AgentTurnToken()
        let requestID = ACPRequestID.string("permission-42")

        fixture.coordinator.resolveAgentPermission(
            runID: runID,
            turnToken: turnToken,
            requestID: requestID,
            optionID: "allow-once")
        await waitUntil {
            await fixture.agentRunner.recordedPermissionResolutions().count == 1
        }

        #expect(await fixture.agentRunner.recordedPermissionResolutions() == [
            ControlledAgentRunner.PermissionResolution(
                turnToken: turnToken,
                requestID: requestID,
                optionID: "allow-once"),
        ])
        await fixture.agentRunner.complete(runIndex: 0)
    }

    @MainActor @Test func execution_WhenProfileUsesCommand_PreservesExistingCommandPath() async throws {
        let profile = try WakeProfile(
            wakePhrase: "computer",
            urlTemplate: "https://example.com/?q={urlText}",
            accent: .blue)
        let fixture = try Fixture(profiles: [profile])
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("computer preserve this", isFinal: true)
        await waitUntil {
            await fixture.runner.recordedTranscripts() == ["preserve this"]
        }

        let expectedTemplate = try profile.commandTemplate
        #expect(await fixture.agentRunner.recordedInvocations().isEmpty)
        #expect(await fixture.runner.recordedTemplates().first == expectedTemplate)
    }

    @MainActor @Test func agentEvent_WhenExecutionGenerationIsStale_IsIgnored() async throws {
        let profile = try makeAgentProfile()
        let fixture = try Fixture(profiles: [profile])
        var lifecycleEvents: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { lifecycleEvents.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent old run", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }

        fixture.coordinator.cancelAgentRun()
        await fixture.agentRunner.emit(.diagnostic("late"), from: 0)
        await fixture.agentRunner.complete(runIndex: 0)
        try await Task.sleep(for: .milliseconds(30))

        #expect(lifecycleEvents.count == 2)
        guard case let .started(runID, _, _) = lifecycleEvents.first else {
            Issue.record("Expected an agent run start")
            return
        }
        #expect(lifecycleEvents.last == .completed(
            runID: runID,
            result: AgentRunResult(stopReason: .cancelled)))
    }

    @MainActor @Test func cancelAgentRun_WhenAgentIsExecuting_CancelsAndResumesPassiveOnce() async throws {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        var lifecycleEvents: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { lifecycleEvents.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent cancel this", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }

        fixture.coordinator.cancelAgentRun()
        fixture.coordinator.cancelAgentRun()
        await waitUntil {
            await fixture.agentRunner.cancelCount == 1
                && fixture.coordinator.state == .listening
        }
        await fixture.agentRunner.emit(.diagnostic("too late"), from: 0)
        await fixture.agentRunner.complete(runIndex: 0)
        try await Task.sleep(for: .milliseconds(30))

        #expect(fixture.speech.startCount == 2)
        #expect(lifecycleEvents.count == 2)
        #expect(fixture.coordinator.state == .listening)
    }

    @MainActor @Test func stop_WhenAgentIsExecuting_ShutsDownRunnerAndIgnoresLateEvents() async throws {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        var lifecycleEvents: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { lifecycleEvents.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent stop this", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }

        fixture.coordinator.stop()
        await waitUntil { await fixture.agentRunner.shutdownCount == 1 }
        await fixture.agentRunner.emit(.diagnostic("too late"), from: 0)
        await fixture.agentRunner.complete(runIndex: 0)
        try await Task.sleep(for: .milliseconds(30))

        #expect(lifecycleEvents.count == 1)
        #expect(fixture.coordinator.state == .disabled)
        #expect(fixture.speech.mode == nil)
    }

    @MainActor @Test func pushToTalk_WhenAgentProfileIsSelected_RoutesToThatHarness() async throws {
        let firstProfile = try makeAgentProfile(displayName: "First")
        let selectedProfile = try makeAgentProfile(displayName: "Selected")
        let fixture = try Fixture(profiles: [firstProfile, selectedProfile])

        fixture.coordinator.pushToTalkPressed(profileID: selectedProfile.id)
        fixture.speech.emit("fix the tests")
        fixture.coordinator.pushToTalkReleased()
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }

        let invocation = await fixture.agentRunner.recordedInvocations()[0]
        #expect(invocation.profileID == selectedProfile.id)
        #expect(invocation.configuration.displayName == "Selected")
        #expect(invocation.prompt == "fix the tests")
        await fixture.agentRunner.complete(runIndex: 0)
    }

    @MainActor @Test func cancelAgentRun_WhenCalledBeforeRunnerEntry_DoesNotStartAgent() async throws {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("agent never start", isFinal: true)
        fixture.coordinator.cancelAgentRun()
        await waitUntil {
            await fixture.agentRunner.cancelCount == 1
                && fixture.coordinator.state == .listening
        }

        #expect(await fixture.agentRunner.recordedInvocations().isEmpty)
        #expect(fixture.speech.startCount == 2)
    }

    @MainActor @Test func stop_WhenCalledBeforeRunnerEntry_DoesNotStartAgent() async throws {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        fixture.coordinator.setPassiveEnabled(true)

        fixture.speech.emit("agent never start", isFinal: true)
        fixture.coordinator.stop()
        await waitUntil { await fixture.agentRunner.shutdownCount == 1 }

        #expect(await fixture.agentRunner.recordedInvocations().isEmpty)
        #expect(fixture.coordinator.state == .disabled)
    }

    @MainActor @Test func cancelAgentRun_WhenCoordinatorIsIdle_IsANoOp() async throws {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])

        fixture.coordinator.cancelAgentRun()
        try await Task.sleep(for: .milliseconds(20))

        #expect(await fixture.agentRunner.cancelCount == 0)
        #expect(fixture.speech.startCount == 0)
        #expect(fixture.coordinator.state == .disabled)
    }

    @MainActor @Test func cancelAgentRun_WhenCommandIsExecuting_IsANoOp() async throws {
        let speech = FakeSpeechSession()
        let commandRunner = ControlledCommandRunner()
        let agentRunner = ControlledAgentRunner()
        let profile = try WakeProfile(
            wakePhrase: "computer",
            urlTemplate: "https://example.com/?q={urlText}",
            accent: .blue)
        let coordinator = VoiceActivationCoordinator(
            speechSession: speech,
            commandRunner: commandRunner,
            agentRunner: agentRunner,
            configuration: {
                ActivationConfiguration(profiles: [profile], localeID: "en-US")
            },
            timing: .fast)
        coordinator.setPassiveEnabled(true)
        speech.emit("computer keep running", isFinal: true)
        await waitUntil {
            await commandRunner.recordedTranscripts() == ["keep running"]
        }

        coordinator.cancelAgentRun()
        try await Task.sleep(for: .milliseconds(20))

        #expect(await agentRunner.cancelCount == 0)
        #expect(coordinator.state == .executing)
        #expect(speech.startCount == 1)

        await commandRunner.completeNext()
        await waitUntil { coordinator.state == .listening }
    }

    @MainActor @Test func pushToTalk_WhenAgentIsAlreadyExecuting_CancelsItBeforeStartingNextAgent() async throws {
        let profile = try makeAgentProfile()
        let fixture = try Fixture(profiles: [profile])
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent first", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }

        fixture.coordinator.pushToTalkPressed(profileID: profile.id)
        fixture.speech.emit("second")
        fixture.coordinator.pushToTalkReleased()
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 2
        }

        #expect(await fixture.agentRunner.cancelCount == 1)
        #expect(await fixture.agentRunner.recordedInvocations().map(\.prompt) == ["first", "second"])
        await fixture.agentRunner.complete(runIndex: 0)
        await fixture.agentRunner.complete(runIndex: 1)
    }

    @MainActor @Test func setPassiveEnabled_WhenAgentIsExecuting_DefersSpeechUntilRunCompletes() async throws {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent keep working", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }

        fixture.coordinator.setPassiveEnabled(false)
        fixture.coordinator.setPassiveEnabled(true)
        try await Task.sleep(for: .milliseconds(20))

        #expect(fixture.speech.startCount == 1)
        #expect(fixture.speech.mode == nil)
        #expect(await fixture.agentRunner.cancelCount == 0)
        #expect(fixture.coordinator.state == .executing)

        await fixture.agentRunner.complete(runIndex: 0)
        await waitUntil { fixture.coordinator.state == .listening }
        #expect(fixture.speech.startCount == 2)
    }

    @MainActor @Test func execution_WhenProfileChangesDuringCapture_UsesSnapshottedAgentAction() async throws {
        let profileID = UUID()
        let agentProfile = try makeAgentProfile(id: profileID, displayName: "Captured")
        let commandProfile = try WakeProfile(
            id: profileID,
            wakePhrase: "agent",
            urlTemplate: "https://changed.example/?q={urlText}",
            accent: .orange)
        var profiles = [agentProfile]
        let speech = FakeSpeechSession()
        let commandRunner = RecordingCommandRunner()
        let agentRunner = ControlledAgentRunner()
        let coordinator = VoiceActivationCoordinator(
            speechSession: speech,
            commandRunner: commandRunner,
            agentRunner: agentRunner,
            configuration: {
                ActivationConfiguration(profiles: profiles, localeID: "en-US")
            },
            timing: .fast)
        coordinator.setPassiveEnabled(true)

        speech.emit("agent inspect")
        profiles = [commandProfile]
        speech.emit("agent inspect", isFinal: true)
        await waitUntil { await agentRunner.recordedInvocations().count == 1 }

        #expect(await agentRunner.recordedInvocations()[0].configuration.displayName == "Captured")
        #expect(await commandRunner.recordedTranscripts().isEmpty)
        await agentRunner.complete(runIndex: 0)
    }

    @MainActor @Test func execution_WhenAgentFails_PublishesFailureAndResumesPassive() async throws {
        let fixture = try Fixture(profiles: [try makeAgentProfile()])
        var states: [ActivationState] = []
        var lifecycleEvents: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onStateChange = { states.append($0) }
        fixture.coordinator.onAgentRunEvent = { lifecycleEvents.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent fail", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }

        await fixture.agentRunner.fail(
            runIndex: 0,
            error: ControlledAgentRunnerError.runFailed)
        await waitUntil { fixture.coordinator.state == .listening }

        #expect(states.contains(.failed("The fake agent run failed.")))
        guard case let .started(runID, _, _) = lifecycleEvents.first else {
            Issue.record("Expected an agent run start")
            return
        }
        #expect(lifecycleEvents.last == .failed(
            runID: runID,
            message: "The fake agent run failed."))
        #expect(fixture.speech.mode == .passiveWake)
    }

    @MainActor @Test func agentCompletion_WhenNewerAgentIsRunning_DoesNotCleanUpNewExecution() async throws {
        let profile = try makeAgentProfile()
        let fixture = try Fixture(profiles: [profile])
        var lifecycleEvents: [AgentRunLifecycleEvent] = []
        fixture.coordinator.onAgentRunEvent = { lifecycleEvents.append($0) }
        fixture.coordinator.setPassiveEnabled(true)
        fixture.speech.emit("agent first", isFinal: true)
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 1
        }
        fixture.coordinator.pushToTalkPressed(profileID: profile.id)
        fixture.speech.emit("second")
        fixture.coordinator.pushToTalkReleased()
        await waitUntil {
            await fixture.agentRunner.recordedInvocations().count == 2
        }

        let runIDs = lifecycleEvents.compactMap { event -> UUID? in
            guard case let .started(runID, _, _) = event else { return nil }
            return runID
        }
        #expect(runIDs.count == 2)
        #expect(runIDs[0] != runIDs[1])

        await fixture.agentRunner.complete(runIndex: 0)
        try await Task.sleep(for: .milliseconds(30))

        #expect(fixture.coordinator.state == .executing)
        #expect(fixture.speech.startCount == 2)
        #expect(fixture.speech.mode == nil)

        await fixture.agentRunner.complete(runIndex: 1)
        await waitUntil { fixture.coordinator.state == .listening }
        #expect(fixture.speech.startCount == 3)
    }

    @MainActor @Test func commandCompletion_WhenNewerCommandIsRunning_IgnoresOlderCompletion() async throws {
        let speech = FakeSpeechSession()
        let runner = ControlledCommandRunner()
        let template = try CommandTemplate(
            executablePath: "/usr/bin/printf",
            argumentTemplates: ["{text}"])
        let coordinator = VoiceActivationCoordinator(
            speechSession: speech,
            commandRunner: runner,
            configuration: {
                ActivationConfiguration(
                    wakePhrase: "computer",
                    localeID: "en-US",
                    commandTemplate: template)
            },
            timing: .fast)
        coordinator.setPassiveEnabled(true)
        speech.emit("computer first", isFinal: true)
        await waitUntil {
            await runner.recordedTranscripts() == ["first"]
        }

        coordinator.pushToTalkPressed()
        speech.emit("second")
        coordinator.pushToTalkReleased()
        await waitUntil {
            await runner.recordedTranscripts() == ["first", "second"]
        }
        await runner.completeNext()
        try await Task.sleep(for: .milliseconds(30))

        #expect(coordinator.state == .executing)
        #expect(speech.mode == nil)

        await runner.completeNext()
        await waitUntil {
            coordinator.state == .listening && speech.mode == .passiveWake
        }
    }

    @MainActor @Test func passiveRestart_WhenPushToTalkCommandStarts_DoesNotPreemptCommand() async throws {
        let speech = FakeSpeechSession()
        let runner = ControlledCommandRunner()
        let template = try CommandTemplate(
            executablePath: "/usr/bin/printf",
            argumentTemplates: ["{text}"])
        let coordinator = VoiceActivationCoordinator(
            speechSession: speech,
            commandRunner: runner,
            configuration: {
                ActivationConfiguration(
                    wakePhrase: "computer",
                    localeID: "en-US",
                    commandTemplate: template)
            },
            timing: .pendingPassiveRestart)
        coordinator.setPassiveEnabled(true)
        speech.emitError("recognizer interrupted")

        coordinator.pushToTalkPressed()
        speech.emit("new command")
        coordinator.pushToTalkReleased()
        await waitUntil {
            await runner.recordedTranscripts() == ["new command"]
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(coordinator.state == .executing)
        #expect(speech.mode == nil)

        await runner.completeNext()
        await waitUntil {
            coordinator.state == .listening && speech.mode == .passiveWake
        }
    }

    @MainActor
    private struct Fixture {
        let speech = FakeSpeechSession()
        let runner = RecordingCommandRunner()
        let agentRunner: ControlledAgentRunner
        let coordinator: VoiceActivationCoordinator

        init(
            timing: ActivationTiming = .standard,
            profiles: [WakeProfile]? = nil,
            agentRunner: ControlledAgentRunner = ControlledAgentRunner()) throws
        {
            self.agentRunner = agentRunner
            let template = try CommandTemplate(
                executablePath: "/usr/bin/printf",
                argumentTemplates: ["{text}"])
            coordinator = VoiceActivationCoordinator(
                speechSession: speech,
                commandRunner: runner,
                agentRunner: agentRunner,
                configuration: {
                    if let profiles {
                        return ActivationConfiguration(profiles: profiles, localeID: "en-US")
                    }
                    return ActivationConfiguration(
                        wakePhrase: "computer",
                        localeID: "en-US",
                        commandTemplate: template)
                },
                timing: timing)
        }
    }

    @MainActor private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () async -> Bool) async
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condition was not satisfied before timeout")
    }
}

private extension ActivationTiming {
    static let fast = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(200),
        captureInactivity: .milliseconds(20),
        captureMaximum: .milliseconds(40),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let startFailure = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(20),
        captureInactivity: .milliseconds(20),
        captureMaximum: .milliseconds(200),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let initialSilence = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(20),
        captureInactivity: .milliseconds(200),
        captureMaximum: .milliseconds(200),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let initialSilenceThenInactivity = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(80),
        captureInactivity: .milliseconds(160),
        captureMaximum: .milliseconds(500),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let repeatingEmptyFinals = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(500),
        captureInactivity: .milliseconds(500),
        captureMaximum: .milliseconds(200),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let wakeHandoff = ActivationTiming(
        wakeHandoffDelay: .milliseconds(20),
        captureInitialSilence: .milliseconds(200),
        captureInactivity: .milliseconds(20),
        captureMaximum: .milliseconds(500),
        passiveRestart: .milliseconds(10),
        executionCooldown: .milliseconds(10))

    static let pendingPassiveRestart = ActivationTiming(
        wakeHandoffDelay: .milliseconds(5),
        captureInitialSilence: .milliseconds(200),
        captureInactivity: .milliseconds(20),
        captureMaximum: .milliseconds(500),
        passiveRestart: .milliseconds(20),
        executionCooldown: .milliseconds(10))
}

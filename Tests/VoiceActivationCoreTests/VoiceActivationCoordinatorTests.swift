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

    @MainActor @Test func pushToTalk_WhenReleased_UsesItsOwnCommandTemplate() async throws {
        let wakeProfile = try WakeProfile(
            wakePhrase: "computer",
            urlTemplate: "https://wake.example/?q={urlText}",
            accent: .blue)
        let pushToTalkTemplate = try CommandTemplate(
            executablePath: "/usr/bin/open",
            argumentTemplates: ["https://push.example/?q={urlText}"])
        let fixture = try Fixture(
            profiles: [wakeProfile],
            pushToTalkTemplate: pushToTalkTemplate)

        fixture.coordinator.pushToTalkPressed()
        fixture.speech.emit("keyboard command")
        fixture.coordinator.pushToTalkReleased()
        await waitUntil {
            await fixture.runner.recordedTranscripts() == ["keyboard command"]
        }

        #expect(await fixture.runner.recordedTemplates() == [pushToTalkTemplate])
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
    private struct Fixture {
        let speech = FakeSpeechSession()
        let runner = RecordingCommandRunner()
        let coordinator: VoiceActivationCoordinator

        init(
            timing: ActivationTiming = .standard,
            profiles: [WakeProfile]? = nil,
            pushToTalkTemplate: CommandTemplate? = nil) throws
        {
            let template = try CommandTemplate(
                executablePath: "/usr/bin/printf",
                argumentTemplates: ["{text}"])
            coordinator = VoiceActivationCoordinator(
                speechSession: speech,
                commandRunner: runner,
                configuration: {
                    if let profiles {
                        return ActivationConfiguration(
                            profiles: profiles,
                            localeID: "en-US",
                            pushToTalkCommandTemplate: pushToTalkTemplate)
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
        timeout: Duration = .seconds(1),
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
}

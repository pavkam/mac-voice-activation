// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import Speech
import VoiceActivationCore

@MainActor
final class AppleSpeechSession: SpeechSessionProtocol {
    enum SessionError: Error, LocalizedError {
        case recognizerUnavailable(String)
        case noAudioInput

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable(let locale):
                "Speech recognition is unavailable for \(locale)."
            case .noAudioInput:
                "No usable microphone input is available."
            }
        }
    }

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let configurationMonitor = AudioEngineConfigurationMonitor()
    private let diagnostics: any VoiceActivationDiagnosticRecording
    private var hasInputTap = false
    private var generation = 0

    init(
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.diagnostics = diagnostics
    }

    func start(
        mode: SpeechSessionMode,
        localeID: String,
        contextualStrings: [String],
        onUpdate: @escaping (SpeechUpdate) -> Void,
        onInterruption: @escaping () -> Void
    ) throws {
        stop()
        let startedAtUptime = DispatchTime.now().uptimeNanoseconds
        generation &+= 1
        let activeGeneration = generation
        diagnostics.record(
            category: .speechRecognition,
            event: "recognition.start_requested",
            fields: [
                "generation": String(activeGeneration),
                "mode": mode.recognitionDiagnosticName,
                "locale": localeID,
                "contextual_phrase_count": String(contextualStrings.count),
            ])
        let locale = Locale(identifier: localeID)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            diagnostics.record(
                category: .speechRecognition,
                event: "recognition.start_failed",
                level: .error,
                fields: [
                    "generation": String(activeGeneration),
                    "mode": mode.recognitionDiagnosticName,
                    "reason": "recognizer_unavailable",
                ])
            throw SessionError.recognizerUnavailable(localeID)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        try SpeechRequestPolicy.configure(
            request,
            mode: mode,
            supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition,
            contextualStrings: contextualStrings)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        SpeechVoiceProcessingPolicy.configure(input, mode: mode)
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            diagnostics.record(
                category: .speechRecognition,
                event: "recognition.start_failed",
                level: .error,
                fields: [
                    "generation": String(activeGeneration),
                    "mode": mode.recognitionDiagnosticName,
                    "reason": "no_audio_input",
                    "channel_count": String(format.channelCount),
                    "sample_rate": String(format.sampleRate),
                ])
            throw SessionError.noAudioInput
        }

        let bufferSink = SpeechAudioBufferSink(request: request)
        input.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: format,
            block: bufferSink.makeTap())
        hasInputTap = true
        recognitionRequest = request
        audioEngine = engine
        configurationMonitor.start(observing: engine) { [weak self] in
            guard let self, self.generation == activeGeneration else { return }
            self.diagnostics.record(
                category: .speechRecognition,
                event: "recognition.audio_configuration_changed",
                level: .warning,
                fields: [
                    "generation": String(activeGeneration),
                    "mode": mode.recognitionDiagnosticName,
                ])
            onInterruption()
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let receivedAtUptime = DispatchTime.now().uptimeNanoseconds
            let transcript = result?.bestTranscription.formattedString ?? ""
            let isFinal = result?.isFinal ?? false
            let errorDescription = error?.localizedDescription
            self?.diagnostics.record(
                category: .speechRecognition,
                event: "recognition.update_received",
                level: error == nil ? .debug : .error,
                fields: [
                    "generation": String(activeGeneration),
                    "mode": mode.recognitionDiagnosticName,
                    "character_count": String(transcript.count),
                    "is_final": String(isFinal),
                    "has_error": String(error != nil),
                    "error_type": error.map { String(describing: type(of: $0)) } ?? "",
                ])
            MainRunLoopScheduler.shared.schedule { [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                let deliveredAtUptime = DispatchTime.now().uptimeNanoseconds
                self.diagnostics.record(
                    category: .speechRecognition,
                    event: "recognition.update_delivering",
                    level: .debug,
                    fields: [
                        "generation": String(activeGeneration),
                        "mode": mode.recognitionDiagnosticName,
                        "task_priority": String(Task.currentPriority.rawValue),
                        "main_delivery_ms": String(
                            Self.milliseconds(
                                from: receivedAtUptime,
                                to: deliveredAtUptime)),
                        "run_loop_mode": RunLoop.current.currentMode?.rawValue ?? "none",
                    ])
                onUpdate(
                    SpeechUpdate(
                        transcript: transcript,
                        isFinal: isFinal,
                        errorDescription: errorDescription))
            }
        }

        do {
            engine.prepare()
            try engine.start()
            diagnostics.record(
                category: .speechRecognition,
                event: "recognition.started",
                fields: [
                    "generation": String(activeGeneration),
                    "mode": mode.recognitionDiagnosticName,
                    "channel_count": String(format.channelCount),
                    "sample_rate": String(format.sampleRate),
                    "on_device_supported": String(recognizer.supportsOnDeviceRecognition),
                    "duration_ms": String(
                        Self.milliseconds(
                            from: startedAtUptime,
                            to: DispatchTime.now().uptimeNanoseconds)),
                    "task_priority": String(Task.currentPriority.rawValue),
                ])
        } catch {
            diagnostics.record(
                category: .speechRecognition,
                event: "recognition.start_failed",
                level: .error,
                fields: [
                    "generation": String(activeGeneration),
                    "mode": mode.recognitionDiagnosticName,
                    "reason": "audio_engine_start",
                    "error_type": String(describing: type(of: error)),
                ])
            stop()
            throw error
        }
    }

    func stop() {
        let previousGeneration = generation
        let hadAudioEngine = audioEngine != nil
        let hadRecognitionTask = recognitionTask != nil
        generation &+= 1
        configurationMonitor.stop()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if hasInputTap, let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        hasInputTap = false
        audioEngine?.stop()
        audioEngine = nil
        diagnostics.record(
            category: .speechRecognition,
            event: "recognition.stopped",
            fields: [
                "previous_generation": String(previousGeneration),
                "generation": String(generation),
                "had_audio_engine": String(hadAudioEngine),
                "had_recognition_task": String(hadRecognitionTask),
            ])
    }

    nonisolated private static func milliseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        guard end >= start else { return 0 }
        return (end - start) / 1_000_000
    }
}

extension SpeechSessionMode {
    fileprivate var recognitionDiagnosticName: String {
        switch self {
        case .passiveWake: "passive_wake"
        case .commandCapture: "command_capture"
        case .conversation: "conversation"
        case .pushToTalk: "push_to_talk"
        }
    }
}

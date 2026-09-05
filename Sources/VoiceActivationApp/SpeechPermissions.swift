// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AVFoundation
import Speech
import VoiceActivationCore

enum SpeechPermissions {
    static func request() async -> Bool {
        await request(diagnostics: VoiceActivationDiagnostics.shared)
    }

    static func request(diagnostics: any VoiceActivationDiagnosticRecording) async -> Bool {
        let microphone = await requestMicrophone(diagnostics: diagnostics)
        guard microphone else {
            diagnostics.record(
                category: .app,
                event: "permissions.pipeline_finished",
                fields: ["granted": "false", "stopped_after": "microphone"])
            return false
        }
        let speechRecognition = await requestSpeechRecognition(diagnostics: diagnostics)
        diagnostics.record(
            category: .app,
            event: "permissions.pipeline_finished",
            fields: [
                "granted": String(speechRecognition),
                "stopped_after": "speech_recognition",
            ])
        return speechRecognition
    }

    private static func requestMicrophone(
        diagnostics: any VoiceActivationDiagnosticRecording
    ) async -> Bool {
        let statusStartedAt = DispatchTime.now().uptimeNanoseconds
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        diagnostics.record(
            category: .app,
            event: "permissions.microphone_status_checked",
            fields: [
                "duration_ms": String(milliseconds(since: statusStartedAt)),
                "status": microphoneStatusName(status),
            ])
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let requestStartedAt = DispatchTime.now().uptimeNanoseconds
            diagnostics.record(
                category: .app,
                event: "permissions.microphone_prompt_started")
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            diagnostics.record(
                category: .app,
                event: "permissions.microphone_prompt_finished",
                fields: [
                    "duration_ms": String(milliseconds(since: requestStartedAt)),
                    "granted": String(granted),
                ])
            return granted
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func requestSpeechRecognition(
        diagnostics: any VoiceActivationDiagnosticRecording
    ) async -> Bool {
        let statusStartedAt = DispatchTime.now().uptimeNanoseconds
        let status = SFSpeechRecognizer.authorizationStatus()
        diagnostics.record(
            category: .app,
            event: "permissions.speech_status_checked",
            fields: [
                "duration_ms": String(milliseconds(since: statusStartedAt)),
                "status": speechStatusName(status),
            ])
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let requestStartedAt = DispatchTime.now().uptimeNanoseconds
            diagnostics.record(
                category: .app,
                event: "permissions.speech_prompt_started")
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            diagnostics.record(
                category: .app,
                event: "permissions.speech_prompt_finished",
                fields: [
                    "duration_ms": String(milliseconds(since: requestStartedAt)),
                    "granted": String(granted),
                ])
            return granted
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func microphoneStatusName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "not_determined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        @unknown default: "unknown"
        }
    }

    private static func speechStatusName(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) -> String {
        switch status {
        case .notDetermined: "not_determined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .authorized: "authorized"
        @unknown default: "unknown"
        }
    }

    private static func milliseconds(since startedAt: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= startedAt ? (now - startedAt) / 1_000_000 : 0
    }
}

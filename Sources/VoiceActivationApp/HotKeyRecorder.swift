// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import Carbon.HIToolbox
import Observation
import VoiceActivationCore

@MainActor
@Observable
final class HotKeyRecorder {
    private(set) var isRecording = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var onCapture: ((PushToTalkHotKey) -> Void)?
    @ObservationIgnored private var onRecordingChange: ((Bool) -> Void)?

    func toggle(
        onCapture: @escaping @MainActor (PushToTalkHotKey) -> Void,
        onRecordingChange: @escaping @MainActor (Bool) -> Void)
    {
        if isRecording {
            stop()
            return
        }

        isRecording = true
        errorMessage = nil
        self.onCapture = onCapture
        self.onRecordingChange = onRecordingChange
        onRecordingChange(true)
    }

    func stop() {
        guard isRecording else { return }
        let lifecycleHandler = onRecordingChange
        isRecording = false
        errorMessage = nil
        onCapture = nil
        onRecordingChange = nil
        lifecycleHandler?(false)
    }

    func capture(_ event: NSEvent) {
        guard isRecording else { return }
        if Int(event.keyCode) == kVK_Escape {
            stop()
            return
        }

        guard let hotKey = HotKeyEventConverter.convert(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers)
        else {
            errorMessage = "Include Control, Option, Shift, or Command."
            return
        }

        let handler = onCapture
        stop()
        handler?(hotKey)
    }
}

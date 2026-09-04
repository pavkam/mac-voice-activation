// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Observation
import VoiceActivationCore

@MainActor
@Observable
final class RecordingOverlayModel {
    var transcript = ""
    var isRecording = false
    var accent: WakeProfileAccent = .blue
    @ObservationIgnored var onCancel: (() -> Void)?
}

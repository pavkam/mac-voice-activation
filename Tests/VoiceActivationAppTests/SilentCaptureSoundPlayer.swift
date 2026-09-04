// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

@testable import VoiceActivationApp

@MainActor
final class SilentCaptureSoundPlayer: CaptureSoundPlaying {
    func play(_ event: CaptureSoundEvent) {}
}

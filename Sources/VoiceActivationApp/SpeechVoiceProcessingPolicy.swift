// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AVFoundation
import VoiceActivationCore

protocol SpeechVoiceProcessingConfiguring: AnyObject {
    func setVoiceProcessingEnabled(_ enabled: Bool) throws
}

extension AVAudioInputNode: SpeechVoiceProcessingConfiguring {}

enum SpeechVoiceProcessingPolicy {
    static func configure(
        _ input: any SpeechVoiceProcessingConfiguring,
        mode: SpeechSessionMode)
    {
        guard mode == .conversation else { return }
        try? input.setVoiceProcessingEnabled(true)
    }
}

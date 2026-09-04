// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Testing
@testable import VoiceActivationApp
@testable import VoiceActivationCore

private final class SpeechVoiceProcessingInputSpy: SpeechVoiceProcessingConfiguring {
    var error: (any Error)?
    private(set) var values: [Bool] = []

    func setVoiceProcessingEnabled(_ enabled: Bool) throws {
        values.append(enabled)
        if let error {
            throw error
        }
    }
}

private enum SpeechVoiceProcessingTestError: Error {
    case unsupported
}

struct SpeechVoiceProcessingPolicyTests {
    @Test func configure_WhenConversationStarts_EnablesEchoCancellation() {
        let input = SpeechVoiceProcessingInputSpy()

        SpeechVoiceProcessingPolicy.configure(input, mode: .conversation)

        #expect(input.values == [true])
    }

    @Test func configure_WhenDeviceRejectsVoiceProcessing_DoesNotFailCaptureSetup() {
        let input = SpeechVoiceProcessingInputSpy()
        input.error = SpeechVoiceProcessingTestError.unsupported

        SpeechVoiceProcessingPolicy.configure(input, mode: .conversation)

        #expect(input.values == [true])
    }

    @Test(arguments: [
        SpeechSessionMode.passiveWake,
        SpeechSessionMode.commandCapture,
        SpeechSessionMode.pushToTalk,
    ])
    func configure_WhenModeDoesNotPlayReplies_LeavesInputUnchanged(
        mode: SpeechSessionMode)
    {
        let input = SpeechVoiceProcessingInputSpy()

        SpeechVoiceProcessingPolicy.configure(input, mode: mode)

        #expect(input.values.isEmpty)
    }
}

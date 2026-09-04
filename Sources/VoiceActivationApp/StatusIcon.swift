// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import VoiceActivationCore

enum StatusIcon {
    static func symbol(for state: ActivationState) -> String {
        switch state {
        case .disabled:
            "mic.slash"
        case .listening:
            "ear"
        case .capturing:
            "waveform"
        case .executing:
            "bolt.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }
}

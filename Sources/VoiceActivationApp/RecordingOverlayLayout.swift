// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit

enum RecordingOverlayLayout {
    static let compactSize = NSSize(width: 126, height: 118)
    static let expandedSize = NSSize(width: 464, height: 118)
    static let transitionDuration: TimeInterval = 0.38

    static func frame(for transcript: String, in visibleFrame: NSRect) -> NSRect {
        let size = transcript.isEmpty ? compactSize : expandedSize
        return NSRect(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.minY + 42,
            width: size.width,
            height: size.height)
    }

    static func shouldAnimate(
        from previousTranscript: String,
        to transcript: String,
        panelIsVisible: Bool) -> Bool
    {
        panelIsVisible && previousTranscript.isEmpty != transcript.isEmpty
    }

    static func shouldUpdateFrame(
        from previousTranscript: String,
        to transcript: String,
        panelIsVisible: Bool) -> Bool
    {
        !panelIsVisible || previousTranscript.isEmpty != transcript.isEmpty
    }
}

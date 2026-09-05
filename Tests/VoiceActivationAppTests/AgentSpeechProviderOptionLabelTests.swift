// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI
import Testing
@testable import VoiceActivationApp

struct AgentSpeechProviderOptionLabelTests {
    @MainActor @Test
    func render_WhenProviderHasSymbol_ReservesGapBetweenSymbolAndTitle() throws {
        let symbol = "waveform.badge.mic"
        let title = "ElevenLabs"

        let symbolWidth = try renderedWidth(Image(systemName: symbol))
        let titleWidth = try renderedWidth(Text(title))
        let optionWidth = try renderedWidth(
            AgentSpeechProviderOptionLabel(title: title, systemImage: symbol))

        #expect(
            optionWidth
                >= symbolWidth + titleWidth + AgentSpeechProviderOptionLabel.spacing)
    }

    @MainActor private func renderedWidth<Content: View>(_ content: Content) throws -> CGFloat {
        let renderer = ImageRenderer(content: content.fixedSize())
        renderer.scale = 1

        return CGFloat(try #require(renderer.cgImage).width)
    }
}

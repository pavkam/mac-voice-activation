// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import VoiceActivationApp

struct SettingsSectionSymbolTests {
    @Test(arguments: SettingsSectionSymbol.allCases)
    func image_WhenUsedBySettingsCard_Resolves(symbol: SettingsSectionSymbol) {
        let image = NSImage(
            systemSymbolName: symbol.rawValue,
            accessibilityDescription: nil)

        #expect(image != nil)
    }
}

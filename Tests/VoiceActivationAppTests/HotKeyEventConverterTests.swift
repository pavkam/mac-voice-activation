// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import Carbon.HIToolbox
import Testing
@testable import VoiceActivationApp
import VoiceActivationCore

struct HotKeyEventConverterTests {
    @Test func convert_WhenLetterAndModifiersArePressed_ReturnsHotKey() throws {
        let hotKey = try #require(HotKeyEventConverter.convert(
            keyCode: UInt16(kVK_ANSI_K),
            modifierFlags: [.control, .shift],
            charactersIgnoringModifiers: "k"))

        #expect(hotKey.keyCode == UInt32(kVK_ANSI_K))
        #expect(hotKey.modifiers == [.control, .shift])
        #expect(hotKey.keyLabel == "K")
    }

    @Test func convert_WhenSpaceIsPressed_UsesReadableLabel() throws {
        let hotKey = try #require(HotKeyEventConverter.convert(
            keyCode: UInt16(kVK_Space),
            modifierFlags: [.control, .option],
            charactersIgnoringModifiers: " "))

        #expect(hotKey == .defaultValue)
    }

    @Test func convert_WhenNoModifierIsPressed_ReturnsNil() {
        let hotKey = HotKeyEventConverter.convert(
            keyCode: UInt16(kVK_ANSI_K),
            modifierFlags: [],
            charactersIgnoringModifiers: "k")

        #expect(hotKey == nil)
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Carbon.HIToolbox
import Foundation
import Testing
@testable import VoiceActivationApp
import VoiceActivationCore

struct PushToTalkShortcutTests {
    @MainActor @Test func carbonModifiers_WhenAllSupportedModifiersArePresent_MapsEveryModifier() {
        let modifiers = PushToTalkShortcut.carbonModifiers(
            for: [.control, .option, .shift, .command])

        #expect(modifiers == UInt32(controlKey | optionKey | shiftKey | cmdKey))
    }

    @MainActor @Test func start_WhenReplacementRegistrationFails_RetainsPreviousHotKey() throws {
        var nextReferenceValue = 1
        var hotKeysByReference: [EventHotKeyRef: PushToTalkHotKey] = [:]
        var failNextRegistration = false
        let backend = PushToTalkShortcut.RegistrationBackend(
            installEventHandler: { _ in
                try #require(EventHandlerRef(bitPattern: 100))
            },
            removeEventHandler: { _ in },
            registerHotKey: { hotKey, _ in
                if failNextRegistration {
                    failNextRegistration = false
                    throw PushToTalkShortcut.RegistrationError.hotKey(-1)
                }
                let reference = try #require(EventHotKeyRef(bitPattern: nextReferenceValue))
                nextReferenceValue += 1
                hotKeysByReference[reference] = hotKey
                return reference
            },
            unregisterHotKey: { reference in
                hotKeysByReference[reference] = nil
            })
        let shortcut = PushToTalkShortcut(registrationBackend: backend)
        let originalHotKey = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        let replacementHotKey = try PushToTalkHotKey(
            keyCode: 45,
            modifiers: [.control, .option],
            keyLabel: "N")
        let profileID = UUID()
        let originalProfile = try WakeProfile(
            id: profileID,
            wakePhrase: "computer",
            urlTemplate: "https://example.com/?q={urlText}",
            accent: .blue,
            pushToTalkHotKey: originalHotKey)
        let replacementProfile = try WakeProfile(
            id: profileID,
            wakePhrase: "computer",
            urlTemplate: "https://example.com/?q={urlText}",
            accent: .blue,
            pushToTalkHotKey: replacementHotKey)
        try shortcut.start(profiles: [originalProfile], onPressed: { _ in }, onReleased: { _ in })
        failNextRegistration = true

        #expect(throws: PushToTalkShortcut.RegistrationError.self) {
            try shortcut.start(
                profiles: [replacementProfile],
                onPressed: { _ in },
                onReleased: { _ in })
        }
        #expect(Set(hotKeysByReference.values) == [originalHotKey])
    }

    @MainActor @Test func start_WhenPhysicalHotKeysDifferOnlyByLabel_RejectsBeforeMutation() throws {
        var nextReferenceValue = 1
        var hotKeysByReference: [EventHotKeyRef: PushToTalkHotKey] = [:]
        var registrationCount = 0
        let backend = PushToTalkShortcut.RegistrationBackend(
            installEventHandler: { _ in
                try #require(EventHandlerRef(bitPattern: 100))
            },
            removeEventHandler: { _ in },
            registerHotKey: { hotKey, _ in
                registrationCount += 1
                let reference = try #require(EventHotKeyRef(bitPattern: nextReferenceValue))
                nextReferenceValue += 1
                hotKeysByReference[reference] = hotKey
                return reference
            },
            unregisterHotKey: { reference in
                hotKeysByReference[reference] = nil
            })
        let shortcut = PushToTalkShortcut(registrationBackend: backend)
        let originalHotKey = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "K")
        let relabeledHotKey = try PushToTalkHotKey(
            keyCode: 40,
            modifiers: [.command, .shift],
            keyLabel: "Key K")
        let originalProfile = try WakeProfile(
            wakePhrase: "computer",
            urlTemplate: "https://example.com/?q={urlText}",
            accent: .blue,
            pushToTalkHotKey: originalHotKey)
        let conflictingProfile = try WakeProfile(
            wakePhrase: "darling",
            urlTemplate: "https://example.com/?q={urlText}",
            accent: .purple,
            pushToTalkHotKey: relabeledHotKey)
        try shortcut.start(
            profiles: [originalProfile],
            onPressed: { _ in },
            onReleased: { _ in })

        #expect(throws: PushToTalkShortcut.RegistrationError.self) {
            try shortcut.start(
                profiles: [originalProfile, conflictingProfile],
                onPressed: { _ in },
                onReleased: { _ in })
        }
        #expect(registrationCount == 1)
        #expect(Set(hotKeysByReference.values) == [originalHotKey])
    }
}

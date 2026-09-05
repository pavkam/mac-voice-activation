// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

private struct PhysicalHotKeyIdentity: Hashable {
    let keyCode: UInt32
    let modifiers: HotKeyModifiers

    init(_ hotKey: PushToTalkHotKey) {
        keyCode = hotKey.keyCode
        modifiers = hotKey.modifiers
    }
}

/// Cross-profile validation failures that cannot be detected by one profile alone.
public enum WakeProfileCollectionValidationError: Error, Equatable, LocalizedError {
    /// The collection does not contain any profile.
    case profileRequired
    /// Two phrases normalize to the same spoken trigger.
    case duplicateWakePhrase
    /// Two profiles reserve the same physical global shortcut.
    case duplicatePushToTalkHotKey

    /// A user-presentable explanation of the collection conflict.
    public var errorDescription: String? {
        switch self {
        case .profileRequired:
            "Add at least one wake profile."
        case .duplicateWakePhrase:
            "Wake phrases must be unique."
        case .duplicatePushToTalkHotKey:
            "Push-to-talk shortcuts must be unique."
        }
    }
}

/// Enforces uniqueness and minimum-content invariants across wake profiles.
public enum WakeProfileCollectionValidator {
    /// Validates the complete profile collection before settings are persisted.
    ///
    /// - Parameter profiles: The proposed saved profiles.
    /// - Throws: ``WakeProfileCollectionValidationError`` for an empty or conflicting collection.
    public static func validate(_ profiles: [WakeProfile]) throws {
        guard !profiles.isEmpty else {
            throw WakeProfileCollectionValidationError.profileRequired
        }

        let phrases = profiles.map { WakePhraseMatcher.canonicalWakePhrase($0.wakePhrase) }
        guard Set(phrases).count == phrases.count else {
            throw WakeProfileCollectionValidationError.duplicateWakePhrase
        }

        let hotKeys = profiles.compactMap(\.pushToTalkHotKey).map(PhysicalHotKeyIdentity.init)
        guard Set(hotKeys).count == hotKeys.count else {
            throw WakeProfileCollectionValidationError.duplicatePushToTalkHotKey
        }
    }
}

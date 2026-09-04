// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

@testable import VoiceActivationCore

final class AppDiagnosticRecorderSpy: VoiceActivationDiagnosticRecording,
    @unchecked Sendable
{
    struct Entry: Sendable {
        let category: VoiceActivationDiagnosticCategory
        let event: String
        let level: VoiceActivationDiagnosticLevel
        let fields: [String: String]
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(
        category: VoiceActivationDiagnosticCategory,
        event: String,
        level: VoiceActivationDiagnosticLevel,
        fields: [String: String]
    ) {
        lock.lock()
        entries.append(
            Entry(
                category: category,
                event: event,
                level: level,
                fields: fields))
        lock.unlock()
    }

    func flush() {}

    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

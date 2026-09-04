// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import VoiceActivationCore

enum AgentPermissionVoiceDecision: Equatable {
    case select(optionID: String)
    case cancel
}

enum AgentPermissionVoiceCommand {
    private static let allowOncePhrases: Set<String> = [
        "allow", "allow once", "approve", "approve once", "yes",
    ]
    private static let allowAlwaysPhrases: Set<String> = [
        "allow all", "allow always", "always allow", "approve all", "always approve",
    ]
    private static let rejectOncePhrases: Set<String> = [
        "deny", "deny once", "no", "reject", "reject once",
    ]
    private static let rejectAlwaysPhrases: Set<String> = [
        "always deny", "always reject", "deny all", "deny always", "never allow",
        "reject all", "reject always",
    ]

    static func match(
        _ transcript: String,
        options: [AgentPermissionOption]) -> AgentPermissionVoiceDecision?
    {
        let phrase = normalized(transcript)
        guard !phrase.isEmpty else { return nil }

        if let exact = options.first(where: { normalized($0.label) == phrase }) {
            return .select(optionID: exact.id)
        }
        if allowAlwaysPhrases.contains(phrase) {
            return selection(
                preferred: .allowAlways,
                fallback: .allowOnce,
                options: options)
        }
        if allowOncePhrases.contains(phrase) {
            return selection(
                preferred: .allowOnce,
                fallback: .allowAlways,
                options: options)
        }
        if rejectAlwaysPhrases.contains(phrase) {
            return selection(
                preferred: .rejectAlways,
                fallback: .rejectOnce,
                options: options) ?? .cancel
        }
        if rejectOncePhrases.contains(phrase) {
            return options.first(where: { $0.kind == .rejectOnce })
                .map { .select(optionID: $0.id) } ?? .cancel
        }
        return nil
    }

    private static func selection(
        preferred: AgentPermissionOptionKind,
        fallback: AgentPermissionOptionKind,
        options: [AgentPermissionOption]) -> AgentPermissionVoiceDecision?
    {
        options.first(where: { $0.kind == preferred })
            .map { .select(optionID: $0.id) }
            ?? options.first(where: { $0.kind == fallback })
                .map { .select(optionID: $0.id) }
    }

    private static func normalized(_ value: String) -> String {
        value
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map {
                String($0).folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US_POSIX"))
            }
            .joined(separator: " ")
    }
}

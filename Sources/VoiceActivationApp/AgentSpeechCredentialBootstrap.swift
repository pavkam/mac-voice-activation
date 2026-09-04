// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

enum AgentSpeechCredentialBootstrapError: Error, Equatable {
    case missingCredential
}

@MainActor
enum AgentSpeechCredentialBootstrap {
    static let argument = "--store-elevenlabs-key-from-stdin"

    static func importIfRequested(
        arguments: [String],
        readCredential: () -> String?,
        store: any AgentSpeechCredentialStoring) throws -> Bool
    {
        guard arguments.dropFirst().contains(argument) else { return false }
        let credential = readCredential()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !credential.isEmpty else {
            throw AgentSpeechCredentialBootstrapError.missingCredential
        }

        try store.saveElevenLabsAPIKey(credential)
        return true
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Security

@MainActor
protocol AgentSpeechCredentialStoring: AnyObject {
    func loadElevenLabsAPIKey() throws -> String?
    func saveElevenLabsAPIKey(_ apiKey: String?) throws
}

enum AgentSpeechCredentialStoreError: Error, LocalizedError {
    case invalidStoredValue
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredValue:
            "The ElevenLabs API key stored in Keychain is invalid."
        case let .keychain(status):
            "Keychain could not save the ElevenLabs API key (status \(status))."
        }
    }
}

@MainActor
final class KeychainAgentSpeechCredentialStore: AgentSpeechCredentialStoring {
    static let service = "dev.alex.voice-activation"
    static let account = "elevenlabs-api-key"

    func loadElevenLabsAPIKey() throws -> String? {
        var item: CFTypeRef?
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AgentSpeechCredentialStoreError.keychain(status)
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw AgentSpeechCredentialStoreError.invalidStoredValue
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func saveElevenLabsAPIKey(_ apiKey: String?) throws {
        let value = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AgentSpeechCredentialStoreError.keychain(status)
            }
            return
        }

        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw AgentSpeechCredentialStoreError.keychain(updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AgentSpeechCredentialStoreError.keychain(addStatus)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}

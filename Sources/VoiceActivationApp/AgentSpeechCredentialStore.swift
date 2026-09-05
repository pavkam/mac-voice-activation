// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Security
import VoiceActivationCore

@MainActor
protocol AgentSpeechCredentialStoring: AnyObject {
    func loadElevenLabsAPIKey() async throws -> String?
    func saveElevenLabsAPIKey(_ apiKey: String?) throws
}

enum AgentSpeechCredentialStoreError: Error, LocalizedError {
    case invalidStoredValue
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredValue:
            "The ElevenLabs API key stored in Keychain is invalid."
        case .keychain(let status):
            "Keychain could not access the ElevenLabs API key (status \(status))."
        }
    }
}

final class AgentSpeechCredentialAccessQueue: @unchecked Sendable {
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queue: DispatchQueue

    init(
        label: String = "dev.alex.voice-activation.keychain",
        qualityOfService: DispatchQoS = .userInitiated
    ) {
        queue = DispatchQueue(label: label, qos: qualityOfService)
        queue.setSpecific(key: queueKey, value: 1)
    }

    var isExecutingOperation: Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }

    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
final class KeychainAgentSpeechCredentialStore: AgentSpeechCredentialStoring {
    nonisolated static let service = "dev.alex.voice-activation"
    nonisolated static let account = "elevenlabs-api-key"

    private nonisolated let accessQueue: AgentSpeechCredentialAccessQueue
    private nonisolated let diagnostics: any VoiceActivationDiagnosticRecording
    private nonisolated let loadOperation: @Sendable () throws -> String?

    init(
        accessQueue: AgentSpeechCredentialAccessQueue = AgentSpeechCredentialAccessQueue(),
        loadOperation: @escaping @Sendable () throws -> String? =
            KeychainAgentSpeechCredentialStore.loadElevenLabsAPIKeySynchronously,
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.accessQueue = accessQueue
        self.loadOperation = loadOperation
        self.diagnostics = diagnostics
    }

    nonisolated func loadElevenLabsAPIKey() async throws -> String? {
        let queuedAt = DispatchTime.now().uptimeNanoseconds
        diagnostics.record(
            category: .settings,
            event: "credential_store.load_queued",
            fields: ["task_priority": String(Task.currentPriority.rawValue)])
        let diagnostics = diagnostics
        let loadOperation = loadOperation
        return try await accessQueue.perform {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            diagnostics.record(
                category: .settings,
                event: "credential_store.load_worker_started",
                fields: [
                    "queue_delay_ms": String(Self.milliseconds(from: queuedAt, to: startedAt)),
                    "uses_dedicated_queue": "true",
                ])
            do {
                let value = try loadOperation()
                let finishedAt = DispatchTime.now().uptimeNanoseconds
                diagnostics.record(
                    category: .settings,
                    event: "credential_store.load_worker_finished",
                    fields: [
                        "has_value": String(value != nil),
                        "operation_duration_ms": String(
                            Self.milliseconds(from: startedAt, to: finishedAt)),
                    ])
                return value
            } catch {
                let finishedAt = DispatchTime.now().uptimeNanoseconds
                diagnostics.record(
                    category: .settings,
                    event: "credential_store.load_worker_failed",
                    level: .error,
                    fields: [
                        "error_type": String(describing: type(of: error)),
                        "operation_duration_ms": String(
                            Self.milliseconds(from: startedAt, to: finishedAt)),
                    ])
                throw error
            }
        }
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

    private nonisolated static func loadElevenLabsAPIKeySynchronously() throws -> String? {
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

    private nonisolated static func milliseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? (end - start) / 1_000_000 : 0
    }

    private nonisolated static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    private var baseQuery: [String: Any] {
        Self.baseQuery
    }
}

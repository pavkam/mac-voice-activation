// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import ServiceManagement
import VoiceActivationCore

protocol LaunchAtLoginServicing: Sendable {
    func isEnabled() async -> Bool

    func setEnabled(_ enabled: Bool) async throws
}

struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let queue = DispatchQueue(
        label: "org.ciobanu.voice-activation.launch-at-login",
        qos: .utility)

    func isEnabled() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let enabled = switch SMAppService.mainApp.status {
                case .enabled, .requiresApproval:
                    true
                case .notFound, .notRegistered:
                    false
                @unknown default:
                    false
                }
                continuation.resume(returning: enabled)
            }
        }
    }

    func setEnabled(_ enabled: Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
@Observable
final class LaunchAtLoginSetting {
    private(set) var isEnabled: Bool
    private(set) var isBusy: Bool
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: any LaunchAtLoginServicing
    @ObservationIgnored private let diagnostics: any VoiceActivationDiagnosticRecording

    init(
        service: any LaunchAtLoginServicing = SystemLaunchAtLoginService(),
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.service = service
        self.diagnostics = diagnostics
        isEnabled = false
        isBusy = false
        diagnostics.record(
            category: .settings,
            event: "launch_at_login.initialized",
            fields: ["system_read": "deferred"])
    }

    func refresh() async {
        guard !isBusy else {
            diagnostics.record(
                category: .settings,
                event: "launch_at_login.refresh_ignored",
                fields: ["reason": "operation_in_progress"])
            return
        }

        isBusy = true
        let startedAt = DispatchTime.now().uptimeNanoseconds
        diagnostics.record(
            category: .settings,
            event: "launch_at_login.refresh_started")

        let observedEnabled = await service.isEnabled()
        isEnabled = observedEnabled
        isBusy = false
        diagnostics.record(
            category: .settings,
            event: "launch_at_login.refresh_finished",
            fields: [
                "duration_ms": String(Self.elapsedMilliseconds(since: startedAt)),
                "observed_enabled": String(observedEnabled),
            ])
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isBusy else {
            diagnostics.record(
                category: .settings,
                event: "launch_at_login.change_ignored",
                fields: [
                    "reason": "operation_in_progress",
                    "requested_enabled": String(enabled),
                ])
            return
        }

        isBusy = true
        let startedAt = DispatchTime.now().uptimeNanoseconds
        diagnostics.record(
            category: .settings,
            event: "launch_at_login.change_requested",
            fields: ["requested_enabled": String(enabled)])

        let changeError: String?
        do {
            try await service.setEnabled(enabled)
            changeError = nil
        } catch {
            changeError = error.localizedDescription
        }

        let observedEnabled = await service.isEnabled()
        errorMessage = changeError
        isEnabled = observedEnabled
        isBusy = false
        diagnostics.record(
            category: .settings,
            event: "launch_at_login.change_finished",
            level: changeError == nil ? .info : .error,
            fields: [
                "duration_ms": String(Self.elapsedMilliseconds(since: startedAt)),
                "requested_enabled": String(enabled),
                "observed_enabled": String(observedEnabled),
                "succeeded": String(changeError == nil),
            ])
    }

    nonisolated private static func elapsedMilliseconds(since start: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= start else { return 0 }
        return (now - start) / 1_000_000
    }
}

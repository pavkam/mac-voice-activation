// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Observation
import ServiceManagement
import VoiceActivationCore

@MainActor
protocol LaunchAtLoginServicing {
    var isEnabled: Bool { get }

    func setEnabled(_ enabled: Bool) throws
}

@MainActor
struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
    var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            true
        case .notFound, .notRegistered:
            false
        @unknown default:
            false
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
@Observable
final class LaunchAtLoginSetting {
    private(set) var isEnabled: Bool
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: any LaunchAtLoginServicing
    @ObservationIgnored private let diagnostics: any VoiceActivationDiagnosticRecording

    init(
        service: any LaunchAtLoginServicing = SystemLaunchAtLoginService(),
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.service = service
        self.diagnostics = diagnostics
        isEnabled = service.isEnabled
        diagnostics.record(
            category: .settings,
            event: "launch_at_login.initialized",
            fields: ["observed_enabled": String(isEnabled)])
    }

    func setEnabled(_ enabled: Bool) {
        diagnostics.record(
            category: .settings,
            event: "launch_at_login.change_requested",
            fields: ["requested_enabled": String(enabled)])
        do {
            try service.setEnabled(enabled)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isEnabled = service.isEnabled
        diagnostics.record(
            category: .settings,
            event: "launch_at_login.change_finished",
            level: errorMessage == nil ? .info : .error,
            fields: [
                "requested_enabled": String(enabled),
                "observed_enabled": String(isEnabled),
                "succeeded": String(errorMessage == nil),
            ])
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Observation
import ServiceManagement

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

    init(service: any LaunchAtLoginServicing = SystemLaunchAtLoginService()) {
        self.service = service
        isEnabled = service.isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            try service.setEnabled(enabled)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isEnabled = service.isEnabled
    }
}

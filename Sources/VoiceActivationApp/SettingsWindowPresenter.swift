// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit

@MainActor
struct SettingsWindowPresenter {
    static let windowID = "settings"
    static let live = SettingsWindowPresenter {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private let activateApplication: () -> Void

    init(activateApplication: @escaping () -> Void) {
        self.activateApplication = activateApplication
    }

    func open(_ openWindow: () -> Void) {
        activateApplication()
        openWindow()
    }
}

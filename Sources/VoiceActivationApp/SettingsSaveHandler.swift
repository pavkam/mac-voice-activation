// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

@MainActor
enum SettingsSaveHandler {
    @discardableResult
    static func perform(save: () async -> Bool, close: () -> Void) async -> Bool {
        let saved = await save()
        if saved {
            close()
        }
        return saved
    }
}

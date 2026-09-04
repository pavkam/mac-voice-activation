// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

struct MenuListeningControlPresentation: Equatable {
    let title: String
    let symbolName: String

    static func make(isListening: Bool) -> MenuListeningControlPresentation {
        if isListening {
            return MenuListeningControlPresentation(
                title: "Pause all",
                symbolName: "pause.circle.fill")
        }

        return MenuListeningControlPresentation(
            title: "Resume all",
            symbolName: "play.circle.fill")
    }
}

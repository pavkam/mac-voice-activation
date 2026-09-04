// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import SwiftUI

@main
struct VoiceActivationApp: App {
    @State private var model: AppModel

    @MainActor
    init() {
        let credentialStore = KeychainAgentSpeechCredentialStore()
        if CommandLine.arguments.dropFirst().contains(AgentSpeechCredentialBootstrap.argument) {
            do {
                if try AgentSpeechCredentialBootstrap.importIfRequested(
                    arguments: CommandLine.arguments,
                    readCredential: { readLine() },
                    store: credentialStore)
                {
                    exit(EXIT_SUCCESS)
                }
            } catch {
                let message = Data("Unable to store the ElevenLabs credential.\n".utf8)
                try? FileHandle.standardError.write(contentsOf: message)
                exit(EXIT_FAILURE)
            }
        }

        _model = State(initialValue: AppModel(agentSpeechCredentialStore: credentialStore))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            let presentation = model.statusPresentation

            Image(systemName: presentation.symbolName)
                .accessibilityLabel(presentation.title)
        }
        .menuBarExtraStyle(.window)

        Window("Voice Activation Settings", id: SettingsWindowPresenter.windowID) {
            SettingsView(model: model)
                .background(SettingsWindowFrontingView())
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)
    }
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI
import YapOpsCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var launchAtLogin: LaunchAtLoginSetting
    @Binding var selectedPane: SettingsPane
    @State private var autosave = SettingsAutosave()

    var body: some View {
        TabView(selection: $selectedPane) {
            Tab(SettingsPane.general.title, systemImage: SettingsPane.general.symbol, value: .general) {
                pane { generalSettings }
            }
            Tab(SettingsPane.profiles.title, systemImage: SettingsPane.profiles.symbol, value: .profiles) {
                pane { profileSettings }
            }
            Tab(SettingsPane.speech.title, systemImage: SettingsPane.speech.symbol, value: .speech) {
                pane { speechSettings }
            }
        }
        .frame(
            width: Design.Layout.settingsWidth,
            height: selectedPane == .general
                ? Design.Layout.settingsHeightGeneral
                : Design.Layout.settingsHeightTall)
        .navigationTitle(selectedPane.title)
        .onChange(of: model.wakeProfiles) { scheduleSave() }
        .onChange(of: model.localeID) { scheduleSave() }
        .onChange(of: model.readsAgentRepliesAloud) { scheduleSave() }
        .onChange(of: model.playsAgentWorkingSound) { scheduleSave() }
        .onChange(of: model.capturesMacContext) { scheduleSave() }
        .onChange(of: model.defaultSpeechVoice) { scheduleSave() }
        .onChange(of: model.elevenLabsAPIKey) { scheduleSave() }
        .onChange(of: model.terminalPhrases) { scheduleSave() }
        .onDisappear {
            // Closing inside the debounce window must not discard the last edit.
            Task { @MainActor in
                await autosave.flush(
                    save: model.saveSettings,
                    errorMessage: { model.settingsError })
            }
        }
        .task(id: model.isStartupReady) {
            guard model.isStartupReady else { return }
            await launchAtLogin.refresh()
        }
    }

    private func pane<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
                .disabled(!model.isStartupReady)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var generalSettings: some View {
        Form {
            Section {
                SettingsToggleRow(
                    title: "Launch at Login",
                    detail: "Start YapOps when you log in. Changes apply immediately.",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { enabled in
                            Task { await launchAtLogin.setEnabled(enabled) }
                        }),
                    isBusy: launchAtLogin.isBusy)
                if let error = launchAtLogin.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Label("Startup", systemImage: "power")
            }
            Section {
                MacContextSettingsSection(model: model)
            } header: {
                Label("Mac context", systemImage: "macwindow")
            }
        }
        .formStyle(.grouped)
    }

    private var profileSettings: some View {
        ProfilesPane(model: model)
    }

    private var speechSettings: some View {
        Form {
            Section {
                SpeechLocalePicker(localeID: $model.localeID)
                SettingsToggleRow(
                    title: "Always listen for wake phrases",
                    detail: "Recognition stays on-device. Changes apply immediately.",
                    isOn: Binding(
                        get: { model.passiveEnabled },
                        set: { model.setPassiveEnabled($0) }))
            } header: {
                Label("Listening", systemImage: "mic")
            } footer: {
                Label(
                    "Push to talk may use Apple’s speech service when on-device recognition is unavailable.",
                    systemImage: "lock.shield")
            }

            Section {
                TerminalPhrasesEditor(phrases: $model.terminalPhrases)
            } header: {
                Label("Conversation phrases", systemImage: "text.bubble")
            } footer: {
                Text(
                    "Saying one of these on its own ends the conversation and "
                        + "closes its panel.")
            }
            SpeechSettingsContent(model: model)
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            SaveIndicator(status: autosave.status)
            Spacer()
        }
    }

    private func scheduleSave() {
        guard model.isStartupReady else { return }
        autosave.edited(
            save: model.saveSettings,
            errorMessage: { model.settingsError })
    }

}

extension WakeProfileAccent {
    var displayName: String { rawValue.capitalized }
}

import AppKit
import SwiftUI

struct MenuContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.state.label)
        if !model.lastTranscript.isEmpty {
            Text("Last: \(MenuTranscriptSummary.format(model.lastTranscript))")
                .lineLimit(1)
        }

        Divider()

        Toggle(
            "Listen for \(model.activeWakeProfiles.count) wake phrase\(model.activeWakeProfiles.count == 1 ? "" : "s")",
            isOn: Binding(
                get: { model.passiveEnabled },
                set: { model.setPassiveEnabled($0) }))

        if model.state == .capturing {
            Button("Cancel Recording") {
                model.cancelCapture()
            }
            .keyboardShortcut(.cancelAction)
        }

        Text("Push to talk: \(model.activePushToTalkHotKey.displayName)")

        Divider()

        Button("Settings…") {
            SettingsWindowPresenter.live.open {
                openWindow(id: SettingsWindowPresenter.windowID)
            }
        }
        .keyboardShortcut(",")

        Button("Quit Voice Activation") {
            model.shutdown()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

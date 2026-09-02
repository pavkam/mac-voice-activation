import AppKit
import SwiftUI

struct MenuContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.state.label)
        if !model.lastTranscript.isEmpty {
            Text("Last: \(model.lastTranscript)")
                .lineLimit(2)
        }

        Divider()

        Toggle(
            "Listen for “\(model.wakePhrase)”",
            isOn: Binding(
                get: { model.passiveEnabled },
                set: { model.setPassiveEnabled($0) }))

        Text("Push to talk: ⌃⌥Space")

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

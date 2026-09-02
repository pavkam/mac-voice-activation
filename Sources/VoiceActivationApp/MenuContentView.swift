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

        ForEach(model.activeWakeProfiles) { profile in
            Toggle(
                "Listen for “\(profile.wakePhrase)”",
                isOn: Binding(
                    get: {
                        model.activeWakeProfiles
                            .first(where: { $0.id == profile.id })?
                            .isEnabled ?? false
                    },
                    set: { model.setWakeProfileEnabled(profile.id, enabled: $0) }))
        }

        if model.state == .capturing {
            Button("Cancel Recording") {
                model.cancelCapture()
            }
            .keyboardShortcut(.cancelAction)
        }

        Divider()

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

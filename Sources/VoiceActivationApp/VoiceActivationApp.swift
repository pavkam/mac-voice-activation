import SwiftUI

@main
struct VoiceActivationApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Image(systemName: StatusIcon.symbol(for: model.state))
                .accessibilityLabel(model.state.label)
        }

        Window("Voice Activation Settings", id: SettingsWindowPresenter.windowID) {
            SettingsView(model: model)
                .background(SettingsWindowFrontingView())
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)
    }
}

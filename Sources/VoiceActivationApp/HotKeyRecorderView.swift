import SwiftUI
import VoiceActivationCore

struct HotKeyRecorderView: View {
    let hotKey: PushToTalkHotKey
    let onChange: @MainActor @Sendable (PushToTalkHotKey) -> Void
    let onRecordingChange: @MainActor @Sendable (Bool) -> Void
    @State private var recorder = HotKeyRecorder()

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Button {
                recorder.toggle(
                    onCapture: onChange,
                    onRecordingChange: onRecordingChange)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: recorder.isRecording ? "record.circle" : "keyboard.badge.ellipsis")
                    Text(recorder.isRecording ? "Press shortcut…" : hotKey.displayName)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .frame(minWidth: 82)
                }
                .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .tint(recorder.isRecording ? .orange : .accentColor)

            HotKeyCaptureView(
                isActive: recorder.isRecording,
                onKeyDown: recorder.capture)
                .frame(width: 0, height: 0)

            if let errorMessage = recorder.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if recorder.isRecording {
                Text("Esc cancels")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear {
            recorder.stop()
        }
    }
}

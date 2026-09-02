import SwiftUI

struct RecordingOverlayView: View {
    @Bindable var model: RecordingOverlayModel

    var body: some View {
        VStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.16))
                    .frame(width: 70, height: 70)
                    .scaleEffect(model.isRecording ? 1.16 : 0.92)
                    .opacity(model.isRecording ? 0.25 : 0.9)
                    .animation(
                        model.isRecording
                            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.15),
                        value: model.isRecording)

                Circle()
                    .fill(LinearGradient(
                        colors: [.accentColor.opacity(0.78), .accentColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                    .frame(width: 54, height: 54)
                    .shadow(color: .accentColor.opacity(0.35), radius: 12)

                Image(systemName: "mic.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(
                        .pulse,
                        options: .repeat(.continuous),
                        isActive: model.isRecording)
            }

            Text(model.transcript.isEmpty ? "Listening…" : model.transcript)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .contentTransition(.interpolate)
                .animation(.snappy(duration: 0.2), value: model.transcript)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 17)
        .frame(width: 430, height: 142)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 24, y: 10)
        .padding(24)
    }
}

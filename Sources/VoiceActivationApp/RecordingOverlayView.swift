import SwiftUI

struct RecordingOverlayView: View {
    @Bindable var model: RecordingOverlayModel

    var body: some View {
        Group {
            if model.transcript.isEmpty {
                compactOverlay
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
            } else {
                expandedOverlay
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: model.transcript.isEmpty)
    }

    private var compactOverlay: some View {
        ZStack(alignment: .topTrailing) {
            microphoneOrb(size: 92)
                .padding(13)

            cancelButton
        }
        .frame(width: 126, height: 118)
        .padding(12)
    }

    private var expandedOverlay: some View {
        HStack(spacing: 16) {
            microphoneOrb(size: 72)

            VStack(alignment: .leading, spacing: 5) {
                Text("Listening")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(1.2)

                Text(model.transcript)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .contentTransition(.interpolate)
                    .animation(.snappy(duration: 0.2), value: model.transcript)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            cancelButton
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(width: 464, height: 118)
        .background {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    LinearGradient(
                        colors: [
                            .cyan.opacity(0.16),
                            .blue.opacity(0.12),
                            .purple.opacity(0.16),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.5), .blue.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    lineWidth: 1)
        }
        .shadow(color: .blue.opacity(0.13), radius: 24, y: 10)
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .padding(12)
    }

    private func microphoneOrb(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)

            Circle()
                .fill(AngularGradient(
                    colors: [.cyan, .blue, .indigo, .purple, .cyan],
                    center: .center))
                .padding(5)
                .shadow(color: .blue.opacity(0.45), radius: 16)

            Circle()
                .stroke(.cyan.opacity(0.42), lineWidth: 3)
                .scaleEffect(model.isRecording ? 1.14 : 0.88)
                .opacity(model.isRecording ? 0.05 : 0.7)
                .animation(
                    model.isRecording
                        ? .easeOut(duration: 1.15).repeatForever(autoreverses: false)
                        : .easeOut(duration: 0.15),
                    value: model.isRecording)

            Image(systemName: "mic.fill")
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(
                    .pulse,
                    options: .repeat(.continuous),
                    isActive: model.isRecording)
        }
        .frame(width: size, height: size)
    }

    private var cancelButton: some View {
        Button {
            model.onCancel?()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary.opacity(0.78))
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.28), lineWidth: 0.75)
                }
        }
        .buttonStyle(.plain)
        .help("Cancel recording")
        .accessibilityLabel("Cancel recording")
    }
}

import SwiftUI

struct RecordingOverlayView: View {
    @Bindable var model: RecordingOverlayModel

    var body: some View {
        ZStack {
            capsuleBackground
                .opacity(isExpanded ? 1 : 0)
                .scaleEffect(
                    x: isExpanded ? 1 : 0.28,
                    y: isExpanded ? 1 : 0.78,
                    anchor: .center)

            HStack(spacing: isExpanded ? 16 : 0) {
                microphoneOrb(size: isExpanded ? 72 : 92)
                    .fixedSize()

                if isExpanded {
                    transcriptContent
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .padding(.horizontal, isExpanded ? 16 : 13)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: isExpanded ? .leading : .center)

            cancelButton
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: isExpanded ? .trailing : .topTrailing)
                .padding(isExpanded ? 14 : 5)
        }
        .animation(
            .smooth(duration: RecordingOverlayLayout.transitionDuration),
            value: isExpanded)
    }

    private var isExpanded: Bool {
        !model.transcript.isEmpty
    }

    private var transcriptContent: some View {
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
        .padding(.trailing, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var capsuleBackground: some View {
        RoundedRectangle(cornerRadius: 32, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                LinearGradient(
                    colors: [
                        accentColor.opacity(0.18),
                        accentColor.opacity(0.08),
                        accentHighlight.opacity(0.16),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.5), accentColor.opacity(0.28)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing),
                        lineWidth: 1)
            }
    }

    private func microphoneOrb(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)

            Circle()
                .fill(AngularGradient(
                    colors: [accentColor, accentHighlight, accentColor.opacity(0.75), accentColor],
                    center: .center))
                .padding(5)
                .shadow(color: accentColor.opacity(0.46), radius: 10)

            Circle()
                .stroke(accentColor.opacity(0.5), lineWidth: 3)
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

    private var accentColor: Color {
        model.accent.swiftUIColor
    }

    private var accentHighlight: Color {
        switch model.accent {
        case .cyan: .blue
        case .blue: .indigo
        case .purple: .pink
        case .pink: .purple
        case .orange: .pink
        case .green: .cyan
        }
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

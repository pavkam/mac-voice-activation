// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI

/// A glance at what a command or system action just did.
///
/// One symbol, one name, and a reason only when there is one. It is an
/// acknowledgement rather than a notification: nothing here is interactive,
/// because the surface leaves on its own and a control the user has two
/// seconds to find is a control that should not exist.
struct ActionFeedbackOverlayView: View {
    @Bindable var model: ActionFeedbackOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let presentation = model.presentation {
                content(for: presentation)
                    .transition(transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(animation, value: model.presentation)
    }

    private func content(for presentation: ActionFeedbackPresentation) -> some View {
        HStack(spacing: Design.Space.overlayGutter) {
            symbol(for: presentation)

            VStack(alignment: .leading, spacing: Design.Space.hairline) {
                Text(presentation.title)
                    .font(Design.Text.statusTitle)
                    .lineLimit(1)
                if let detail = presentation.detail {
                    Text(detail)
                        .font(Design.Text.statusDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Space.overlayGutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private func symbol(for presentation: ActionFeedbackPresentation) -> some View {
        ZStack {
            Circle()
                .fill(tint(for: presentation.tone).opacity(Design.Alpha.accentBadge))
            Image(systemName: presentation.symbolName)
                .font(Design.Text.rowTitle)
                .foregroundStyle(tint(for: presentation.tone))
                // The running state needs a signal that is not colour, and one
                // that stops when the work does.
                .symbolEffect(.pulse, isActive: presentation.tone == .working && !reduceMotion)
        }
        .frame(width: Design.Layout.orbIdle, height: Design.Layout.orbIdle)
    }

    private func tint(for tone: ActionFeedbackPresentation.Tone) -> Color {
        switch tone {
        case .working: Design.Color.accentFallback
        case .success: Design.Color.success
        case .failure: Design.Color.danger
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: Design.Radius.capsule, style: .continuous)
            .fill(Design.Material.floating)
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.capsule, style: .continuous)
                    .strokeBorder(
                        .white.opacity(Design.Alpha.hairline),
                        lineWidth: Design.Border.hairline)
            }
    }

    private var animation: Animation {
        reduceMotion ? Design.Motion.quick : Design.Motion.snappy
    }

    private var transition: AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: .bottom).combined(with: .opacity)
    }
}

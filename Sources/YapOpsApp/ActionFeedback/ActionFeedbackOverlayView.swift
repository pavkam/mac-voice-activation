// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI

/// A glance at what a command or system action just did.
///
/// One symbol, one name, and a reason only when there is one. It is an
/// acknowledgement rather than a notification: nothing here is interactive,
/// because the surface leaves on its own and a control the user has two
/// seconds to find is a control that should not exist.
///
/// The card sizes itself to its content and centres in the panel, so it reads
/// as a settled object rather than a box with a symbol parked at one end.
struct ActionFeedbackOverlayView: View {
    @Bindable var model: ActionFeedbackOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let presentation = model.presentation {
                card(for: presentation)
                    .transition(transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(animation, value: model.presentation)
    }

    private func card(for presentation: ActionFeedbackPresentation) -> some View {
        HStack(spacing: Design.Space.card) {
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
                        .frame(maxWidth: Design.Layout.feedbackDetailWidth, alignment: .leading)
                }
            }
        }
        .fixedSize()
        .padding(.leading, Design.Space.small)
        .padding(.trailing, Design.Space.panelContent)
        .padding(.vertical, Design.Space.small)
        .background(background(for: presentation))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private func symbol(for presentation: ActionFeedbackPresentation) -> some View {
        let tint = tint(for: presentation.tone)
        return ZStack {
            Circle()
                .fill(tint.opacity(Design.Alpha.accentBadge))
                .overlay {
                    Circle()
                        .strokeBorder(
                            tint.opacity(Design.Alpha.accentBorder),
                            lineWidth: Design.Border.hairline)
                }
            Image(systemName: presentation.symbolName)
                .font(Design.Text.rowTitle)
                .foregroundStyle(tint)
                // The running state needs a signal that is not colour, and one
                // that stops when the work does.
                .symbolEffect(.pulse, isActive: presentation.tone == .working && !reduceMotion)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: Design.Layout.iconBadge, height: Design.Layout.iconBadge)
    }

    private func tint(for tone: ActionFeedbackPresentation.Tone) -> Color {
        switch tone {
        case .working: Design.Color.accentFallback
        case .success: Design.Color.success
        case .failure: Design.Color.danger
        }
    }

    private func background(for presentation: ActionFeedbackPresentation) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: presentation.detail == nil
                ? Design.Radius.capsule
                : Design.Radius.panelExpanded,
            style: .continuous)
        return shape
            .fill(Design.Material.floating)
            .overlay {
                shape.strokeBorder(
                    .white.opacity(Design.Alpha.hairlineCard),
                    lineWidth: Design.Border.hairline)
            }
            .shadow(
                color: .black.opacity(Design.Glow.feedbackCard.alpha),
                radius: Design.Glow.feedbackCard.radius,
                y: Design.Glow.feedbackCard.y)
    }

    private var animation: Animation {
        reduceMotion ? Design.Motion.quick : Design.Motion.dock
    }

    /// The card grows out of where the recording orb was rather than sliding
    /// in from somewhere the interaction never was.
    private var transition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.86, anchor: .center).combined(with: .opacity)
    }
}

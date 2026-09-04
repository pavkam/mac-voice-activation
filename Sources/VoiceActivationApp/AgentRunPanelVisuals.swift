// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI

struct AgentRunPanelBackdrop: View {
    let accent: Color
    let highlight: Color
    let isActive: Bool
    let isCompact: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            LinearGradient(
                colors: [
                    baseColor,
                    accent.opacity(colorScheme == .dark ? 0.11 : 0.07),
                    baseColor.opacity(0.96),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)

            RadialGradient(
                colors: [accent.opacity(isActive ? 0.30 : 0.18), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: isCompact ? 210 : 390)
                .offset(x: isActive ? -12 : -34, y: isActive ? -8 : -24)
                .animation(.smooth(duration: 0.8), value: isActive)

            RadialGradient(
                colors: [highlight.opacity(isActive ? 0.18 : 0.11), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: isCompact ? 170 : 360)

            LinearGradient(
                colors: [.white.opacity(0.09), .clear, .black.opacity(0.10)],
                startPoint: .top,
                endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var baseColor: Color {
        colorScheme == .dark
            ? Color(red: 0.055, green: 0.06, blue: 0.085).opacity(0.88)
            : Color.white.opacity(0.72)
    }
}

struct AgentRunPhaseOrb: View {
    let symbol: String
    let accent: Color
    let highlight: Color
    let size: CGFloat
    let symbolSize: CGFloat
    let isActive: Bool
    let isFailed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isActive && !reduceMotion {
                PhaseAnimator([false, true]) { expanded in
                    Circle()
                        .stroke(accent.opacity(expanded ? 0.04 : 0.48), lineWidth: 1.5)
                        .scaleEffect(expanded ? 1.34 : 0.94)
                } animation: { _ in
                    .easeOut(duration: 1.35)
                }
            } else {
                Circle()
                    .stroke(accent.opacity(isActive ? 0.36 : 0.16), lineWidth: 1)
                    .scaleEffect(1.10)
            }

            Circle()
                .fill(.thinMaterial)

            Circle()
                .fill(AngularGradient(
                    colors: orbColors,
                    center: .center))
                .padding(3)

            Circle()
                .stroke(.white.opacity(0.34), lineWidth: 0.8)
                .padding(3)

            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: isActive)
                .shadow(color: .black.opacity(0.24), radius: 2, y: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: orbTint.opacity(isActive ? 0.42 : 0.22), radius: isActive ? 14 : 8)
        .accessibilityHidden(true)
    }

    private var orbTint: Color {
        isFailed ? .red : accent
    }

    private var orbColors: [Color] {
        if isFailed {
            return [.red, .orange, .red.opacity(0.72), .red]
        }
        return [accent, highlight, accent.opacity(0.68), accent]
    }
}

struct AgentRunWorkingGlyph: View {
    let tint: Color
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRotating = false

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.13))

            Circle()
                .trim(from: 0.08, to: 0.74)
                .stroke(
                    AngularGradient(
                        colors: [.clear, tint.opacity(0.48), tint, .clear],
                        center: .center),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(3)
                .rotationEffect(.degrees(isRotating ? 360 : 0))

            Image(systemName: "sparkle")
                .font(.system(size: size * 0.30, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                isRotating = true
            }
        }
        .accessibilityHidden(true)
    }
}

enum AgentRunActionButtonRole {
    case subtle
    case accent
    case danger
}

struct AgentRunActionButtonStyle: ButtonStyle {
    let role: AgentRunActionButtonRole
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                Capsule(style: .continuous)
                    .fill(fillGradient)
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(.white.opacity(role == .subtle ? 0.13 : 0.24), lineWidth: 0.7)
            }
            .shadow(color: shadowColor, radius: role == .subtle ? 0 : 7, y: 3)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        role == .subtle ? .primary : .white
    }

    private var fillGradient: LinearGradient {
        switch role {
        case .subtle:
            LinearGradient(
                colors: [.white.opacity(0.075), .white.opacity(0.035)],
                startPoint: .top,
                endPoint: .bottom)
        case .accent:
            LinearGradient(
                colors: [tint.opacity(0.94), tint.opacity(0.64)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
        case .danger:
            LinearGradient(
                colors: [.red.opacity(0.92), .pink.opacity(0.62)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
        }
    }

    private var shadowColor: Color {
        switch role {
        case .subtle: .clear
        case .accent: tint.opacity(0.28)
        case .danger: .red.opacity(0.24)
        }
    }
}

struct AgentRunIconButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary.opacity(configuration.isPressed ? 0.62 : 0.82))
            .frame(width: 30, height: 30)
            .background(.white.opacity(configuration.isPressed ? 0.11 : 0.065), in: Circle())
            .overlay {
                Circle().stroke(.white.opacity(0.12), lineWidth: 0.7)
            }
            .shadow(color: tint.opacity(0.12), radius: 6, y: 2)
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

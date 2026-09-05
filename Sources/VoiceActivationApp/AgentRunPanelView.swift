// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI
import VoiceActivationCore

/// Renders the movable expanded conversation panel and its compact notification form.
struct AgentRunPanelView: View {
    @Bindable var model: AgentRunPanelModel
    /// The system motion preference used by panel transitions.
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// The retained panel hierarchy whose geometry animates between presentation modes.
    var body: some View {
        let cornerRadius: CGFloat = model.isMinimized ? 24 : 30
        ZStack {
            AgentRunPanelBackdrop(
                accent: accent,
                highlight: accentHighlight,
                isActive: model.snapshot?.phase == .running,
                isCompact: model.isMinimized)
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.42),
                            .white.opacity(0.10),
                            accent.opacity(0.36),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    lineWidth: 0.8)
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .animation(
            .snappy(duration: AgentRunPanelLayout.transitionDuration),
            value: model.isMinimized)
    }

    @ViewBuilder
    var content: some View {
        if let snapshot = model.snapshot {
            if model.isMinimized {
                compactContent(snapshot)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else {
                expandedContent(snapshot)
                    .transition(.scale(scale: 0.98).combined(with: .opacity))
            }
        }
    }

    func expandedContent(_ snapshot: AgentRunSnapshot) -> some View {
        VStack(spacing: 0) {
            header(snapshot)
            panelSeparator
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        requestCard(snapshot)
                        plan(snapshot)
                        timeline(snapshot)
                        noticeCards(snapshot)
                        failureCard(snapshot)
                        permissions(snapshot)
                        Color.clear.frame(height: 1).id("agent-run-bottom")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 14)
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(
                        0,
                        geometry.contentSize.height
                            - geometry.contentOffset.y
                            - geometry.containerSize.height)
                } action: { _, distanceFromBottom in
                    model.updateScrollGeometry(distanceFromBottom: distanceFromBottom)
                }
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    let wasUserScrolling = oldPhase == .interacting
                        || oldPhase == .decelerating
                    let isUserScrolling = newPhase == .interacting
                        || newPhase == .decelerating
                    guard wasUserScrolling || isUserScrolling else { return }
                    let geometry = context.geometry
                    let distance = max(
                        0,
                        geometry.contentSize.height
                            - geometry.contentOffset.y
                            - geometry.containerSize.height)
                    if isUserScrolling {
                        model.beginUserScrolling(distanceFromBottom: distance)
                    } else {
                        model.endUserScrolling(distanceFromBottom: distance)
                    }
                }
                .onChange(of: snapshot.timeline) {
                    followBottom(proxy)
                }
                .onChange(of: snapshot.notices) {
                    followBottom(proxy)
                }
                .onChange(of: snapshot.plan) {
                    followBottom(proxy)
                }
                .onChange(of: snapshot.permissions) {
                    followBottom(proxy)
                }
                .onChange(of: snapshot.phase) {
                    followBottom(proxy)
                }
            }
            actionDock(snapshot)
        }
    }

    func followBottom(_ proxy: ScrollViewProxy) {
        guard model.isAutoFollowing else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo("agent-run-bottom", anchor: .bottom)
        }
    }

    func header(_ snapshot: AgentRunSnapshot) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 13) {
                phaseIcon(snapshot, size: 44, symbolSize: 17)

                Text(snapshot.providerName)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .tracking(-0.25)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay { AgentRunPanelDragSurface() }

            AgentRunElapsedTimeView(
                phase: snapshot.phase,
                elapsedSeconds: snapshot.elapsedSeconds,
                startedAt: model.elapsedStartedAt)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(.white.opacity(0.055), in: Capsule())
                .overlay {
                    Capsule().stroke(.white.opacity(0.10), lineWidth: 0.7)
                }

            Button {
                model.onAction?(.minimize(runID: snapshot.runID))
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(AgentRunIconButtonStyle(tint: accent))
            .help("Minimize conversation")
            .accessibilityLabel("Minimize conversation")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background {
            LinearGradient(
                colors: [.white.opacity(0.045), .clear],
                startPoint: .top,
                endPoint: .bottom)
        }
    }

    func compactContent(_ snapshot: AgentRunSnapshot) -> some View {
        HStack(spacing: 13) {
            HStack(spacing: 13) {
                phaseIcon(snapshot, size: 48, symbolSize: 18)

                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.providerName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(compactStatus(snapshot))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay { AgentRunPanelDragSurface() }

            AgentRunElapsedTimeView(
                phase: snapshot.phase,
                elapsedSeconds: snapshot.elapsedSeconds,
                startedAt: model.elapsedStartedAt)

            Button {
                model.onAction?(.restore(runID: snapshot.runID))
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(AgentRunIconButtonStyle(tint: accent))
            .help("Restore conversation")
            .accessibilityLabel("Restore conversation")
        }
        .padding(.horizontal, 15)
    }

    func phaseIcon(
        _ snapshot: AgentRunSnapshot,
        size: CGFloat,
        symbolSize: CGFloat) -> some View
    {
        AgentRunPhaseOrb(
            symbol: phaseSymbol(snapshot.phase),
            accent: accent,
            highlight: accentHighlight,
            size: size,
            symbolSize: symbolSize,
            isActive: snapshot.phase == .running,
            isFailed: {
                if case .failed = snapshot.phase { return true }
                return false
            }())
    }

}

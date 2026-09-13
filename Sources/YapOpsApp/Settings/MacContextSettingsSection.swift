// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI

struct MacContextSettingsPresentation {
    enum State {
        case off
        case appOnly
        case ready
    }

    let accessStatus: MacContextAccessStatus
    var isEnabled = true

    let toggleLabel = "Include Mac context"
    let disclosureText = "When enabled, YapOps sends the focused app’s name and bundle identifier, focused window title and document URL, selected text, and up to eight selected resource links outside YapOps to the selected ACP provider."

    var state: State {
        guard isEnabled else { return .off }
        return accessStatus == .authorized ? .ready : .appOnly
    }

    var accessStatusText: String {
        switch state {
        case .off: "Mac context is off"
        case .appOnly: "App name only"
        case .ready: "Ready for Mac context"
        }
    }

    var detailText: String {
        switch state {
        case .off:
            "Agent requests use only what you say. Turn context on to refer to the app you’re using."
        case .appOnly:
            "Enable Accessibility to include window details, selected text, and selected files."
        case .ready:
            "Say “summarize this” or “use these files.” YapOps includes the selection your app makes available."
        }
    }

    var symbolName: String {
        switch state {
        case .off: "rectangle.slash"
        case .appOnly: "exclamationmark.circle.fill"
        case .ready: "checkmark.circle.fill"
        }
    }

    var showsEnableAccessibilityButton: Bool {
        state == .appOnly
    }
}

@MainActor
struct MacContextSettingsActions {
    let enableAccessibility: () -> Void
    let appear: () -> Void
    let refresh: () -> Void

    init(model: AppModel) {
        enableAccessibility = model.requestMacContextAccess
        appear = model.settingsDidAppear
        refresh = model.refreshMacContextAccessStatus
    }
}

struct MacContextSettingsSection: View {
    @Bindable var model: AppModel
    @State private var poller = MacContextAccessPoller()

    private var actions: MacContextSettingsActions {
        MacContextSettingsActions(model: model)
    }

    var body: some View {
        MacContextSettingsContent(
            isEnabled: $model.capturesMacContext,
            accessStatus: model.macContextAccessStatus,
            enableAccessibility: actions.enableAccessibility,
            refresh: actions.refresh)
            .onAppear {
                actions.appear()
                startPolling()
            }
            .onDisappear { poller.stop() }
            .onChange(of: model.macContextAccessStatus) { startPolling() }
    }

    private func startPolling() {
        poller.start(
            refresh: actions.refresh,
            isAuthorized: { model.macContextAccessStatus == .authorized })
    }
}

struct MacContextSettingsContent: View {
    @Binding var isEnabled: Bool
    let accessStatus: MacContextAccessStatus
    let enableAccessibility: () -> Void
    var refresh: () -> Void = {}

    private var presentation: MacContextSettingsPresentation {
        MacContextSettingsPresentation(accessStatus: accessStatus, isEnabled: isEnabled)
    }

    private var statusColor: Color {
        switch presentation.state {
        case .off: .secondary
        case .appOnly: .orange
        case .ready: .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsToggleRow(
                title: presentation.toggleLabel,
                detail: "Share the focused app, window, selected text, and file links with your agent.",
                isOn: $isEnabled)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: presentation.symbolName)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.accessStatusText)
                        .font(.caption.weight(.semibold))
                    Text(presentation.detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            if presentation.showsEnableAccessibilityButton {
                HStack(spacing: 8) {
                    Button("Enable Accessibility…", action: enableAccessibility)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help("Approve YapOps in System Settings, then return here.")

                    // macOS can hold this process's trust check stale right
                    // after the checkbox is toggled, particularly off then
                    // back on. A manual recheck is a guaranteed lever when the
                    // automatic one hasn't caught up yet.
                    Button("Recheck", systemImage: "arrow.clockwise", action: refresh)
                        .buttonStyle(.borderless)
                        .controlSize(.regular)
                        .help("Already approved it in System Settings? Check again.")
                }
            }

            DisclosureGroup("What your agent receives") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(presentation.disclosureText)
                    Text("Screenshots, clipboard content, and file contents are never included.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }
}

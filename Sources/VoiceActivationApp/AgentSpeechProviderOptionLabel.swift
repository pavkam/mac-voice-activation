// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI

/// Renders a speech-provider name and symbol as one accessible picker label.
struct AgentSpeechProviderOptionLabel: View {
    /// The visual gap between the provider symbol and name.
    static let spacing: CGFloat = 6

    /// The user-visible provider name.
    let title: String
    /// The SF Symbol associated with the provider.
    let systemImage: String

    /// The combined provider label presented to SwiftUI and accessibility.
    var body: some View {
        HStack(spacing: Self.spacing) {
            Image(systemName: systemImage)
            Text(title)
        }
        .accessibilityElement(children: .combine)
    }
}

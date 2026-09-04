// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI

struct VoiceActivationMark: View {
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(LinearGradient(
                    colors: [tint, tint.opacity(0.62), .indigo.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))

            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(.white.opacity(0.28), lineWidth: 1)

            HStack(alignment: .center, spacing: 2.5) {
                ForEach(
                    Array([8.0, 14.0, 20.0, 25.0, 20.0, 14.0, 8.0].enumerated()),
                    id: \.offset)
                { _, height in
                    Capsule()
                        .fill(.white)
                        .frame(width: 2.7, height: height)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
        .shadow(color: tint.opacity(0.26), radius: 10, y: 4)
        .accessibilityHidden(true)
    }
}

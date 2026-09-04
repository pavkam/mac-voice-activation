// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import SwiftUI

struct AgentMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(AgentMarkdownFormatter.blocks(from: markdown).enumerated()), id: \.offset) {
                _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AgentMarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            inlineText(text)
                .font(.system(
                    size: headingSize(level),
                    weight: level <= 2 ? .bold : .semibold,
                    design: .rounded))
        case let .paragraph(text):
            inlineText(text)
                .font(.system(size: 13, design: .rounded))
                .lineSpacing(3)
        case let .unorderedListItem(depth, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(.secondary)
                    .frame(width: 4, height: 4)
                inlineText(text)
                    .font(.system(size: 13, design: .rounded))
            }
            .padding(.leading, CGFloat(depth * 14))
        case let .orderedListItem(depth, number, text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(number).")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16, alignment: .trailing)
                inlineText(text)
                    .font(.system(size: 13, design: .rounded))
            }
            .padding(.leading, CGFloat(depth * 14))
        case let .quote(text):
            HStack(alignment: .top, spacing: 9) {
                Capsule()
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 3)
                inlineText(text)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        case let .code(language, text):
            VStack(alignment: .leading, spacing: 5) {
                if let language {
                    Text(language.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .tracking(0.7)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
        case .divider:
            Divider().opacity(0.55)
        }
    }

    private func inlineText(_ markdown: String) -> Text {
        Text(AgentMarkdownFormatter.attributedString(from: markdown))
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 18
        case 2: 16
        case 3: 15
        default: 13
        }
    }
}

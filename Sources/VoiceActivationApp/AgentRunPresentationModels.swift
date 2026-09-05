// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import VoiceActivationCore

/// The panel-visible phase of a retained agent conversation.
enum AgentRunPhase: Equatable, Sendable {
    case listening
    case running
    case cancelling
    case completed(AgentStopReason)
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .completed, .failed:
            true
        case .listening, .running, .cancelling:
            false
        }
    }

    /// Whether the elapsed clock should advance while this phase is visible.
    ///
    /// Follow-up listening is intentionally excluded: the clock measures agent work,
    /// not how long the user leaves a conversation window open.
    var advancesElapsedTime: Bool {
        switch self {
        case .running, .cancelling:
            true
        case .listening, .completed, .failed:
            false
        }
    }
}

/// Correlates one permission prompt with the exact local turn and JSON-RPC request.
struct AgentPermissionKey: Hashable, Sendable {
    let turnToken: AgentTurnToken
    let requestID: ACPRequestID
}

/// Immutable display state for one pending or resolving permission request.
struct AgentPermissionPresentation: Equatable, Identifiable, Sendable {
    var id: AgentPermissionKey { key }

    let key: AgentPermissionKey
    let toolTitle: String
    let options: [AgentPermissionOption]
    var isResolving: Bool
}

/// The merged presentation state of a tool call and its partial updates.
struct AgentToolPresentation: Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    var kind: AgentToolKind?
    var status: AgentToolCallStatus?
    var isSettled = false

    var isWorking: Bool {
        !isSettled && (status == nil || status == .pending || status == .inProgress)
    }

    var isFinished: Bool {
        isSettled || status == .completed || status == .failed
    }
}

/// A stable identity for heterogeneous reasoning and tool details.
enum AgentThinkingDetailID: Hashable, Sendable {
    case thought(UUID)
    case tool(String)
}

/// One expandable detail retained inside a grouped thinking interval.
enum AgentThinkingDetail: Equatable, Identifiable, Sendable {
    case thought(AgentMessagePresentation)
    case tool(AgentToolPresentation)

    var id: AgentThinkingDetailID {
        switch self {
        case .thought(let message): .thought(message.id)
        case .tool(let tool): .tool(tool.id)
        }
    }
}

/// A bounded group of reasoning and tool activity between user-visible responses.
struct AgentThinkingPresentation: Equatable, Identifiable, Sendable {
    let id: UUID
    var details: [AgentThinkingDetail]
    var omittedDetailCount: UInt64 = 0
    var isSettled = false

    var isWorking: Bool { !isSettled }

    var hasFailedTool: Bool {
        details.contains { detail in
            guard case .tool(let tool) = detail else { return false }
            return tool.status == .failed
        }
    }
}

/// Distinguishes visible response Markdown from collapsible agent reasoning.
enum AgentMessagePresentationKind: Equatable, Sendable {
    case response
    case thought
}

/// A coalesced streaming agent message with stable presentation identity.
struct AgentMessagePresentation: Equatable, Identifiable, Sendable {
    let id: UUID
    let messageID: String?
    let kind: AgentMessagePresentationKind
    var text: String
}

/// One submitted user utterance retained in conversation order.
struct AgentUserMessagePresentation: Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
}

/// A stable identity for heterogeneous conversation timeline entries.
enum AgentRunTimelineItemID: Hashable, Sendable {
    case omitted
    case message(UUID)
    case userMessage(UUID)
    case thinking(UUID)
}

/// One response, user message, thinking group, or bounded-omission marker.
enum AgentRunTimelineItem: Equatable, Identifiable, Sendable {
    case omitted
    case message(AgentMessagePresentation)
    case userMessage(AgentUserMessagePresentation)
    case thinking(AgentThinkingPresentation)

    var id: AgentRunTimelineItemID {
        switch self {
        case .omitted: .omitted
        case .message(let message): .message(message.id)
        case .userMessage(let message): .userMessage(message.id)
        case .thinking(let thinking): .thinking(thinking.id)
        }
    }
}

/// The immutable, bounded state rendered by all agent-conversation surfaces.
struct AgentRunSnapshot: Equatable, Sendable {
    let runID: UUID
    let profileID: UUID
    let accent: WakeProfileAccent
    let prompt: String
    let providerName: String
    let phase: AgentRunPhase
    let voiceInput: String
    let output: String
    let timeline: [AgentRunTimelineItem]
    let diagnostics: String
    let plan: [AgentPlanEntry]
    let tools: [AgentToolPresentation]
    let permissions: [AgentPermissionPresentation]
    let notices: [String]
    let elapsedSeconds: Int
    let evictedToolCount: UInt64
    let ignoredToolUpdateCount: UInt64

    /// A plain-text export containing only the retained request, response, and diagnostics.
    var copyText: String {
        var sections = ["Request\n\(prompt)"]
        if !output.isEmpty {
            sections.append("Response\n\(output)")
        }
        if !diagnostics.isEmpty {
            sections.append("Diagnostics\n\(diagnostics)")
        }
        return sections.joined(separator: "\n\n")
    }
}

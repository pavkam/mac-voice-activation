// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import YapOpsCore

/// The panel-visible phase of a retained agent conversation.
enum AgentRunPhase: Equatable, Sendable {
    case listening
    case paused
    case running
    case cancelling
    case completed(AgentStopReason)
    case failed(String)

    /// Whether the conversation is actively working.
    ///
    /// `paused` is deliberately excluded: a muted microphone must not look
    /// alive, so the phase pip and every other ambient motion stay inert while
    /// paused. Ambient motion in this application means work is happening.
    var isLive: Bool {
        switch self {
        case .listening, .running:
            true
        case .paused, .cancelling, .completed, .failed:
            false
        }
    }

    /// Whether the composer should show the microphone as live and accept a
    /// spoken transcript for this phase.
    ///
    /// `.paused` is the only non-terminal phase where the microphone is
    /// genuinely off; every other non-terminal phase — including `.running`,
    /// since YapOps accepts a spoken follow-up while the agent is still
    /// working — keeps it live. A terminal phase has no composer to show it
    /// in, but this stays exhaustive rather than relying on that invariant
    /// holding at every call site.
    var acceptsSpokenFollowUp: Bool {
        switch self {
        case .listening, .running, .cancelling:
            true
        case .paused, .completed, .failed:
            false
        }
    }

    /// What the composer's microphone button does in this phase.
    ///
    /// There is no independent mute: the only way to silence the microphone
    /// while a run is not already paused is to stop what it is doing, so the
    /// label says exactly that rather than a softer "Pause listening" a mute
    /// control would carry.
    var microphoneActionLabel: String {
        switch self {
        case .listening:
            "Stop listening"
        case .paused:
            "Resume listening"
        case .running, .cancelling, .completed, .failed:
            "Stop turn"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed:
            true
        case .listening, .paused, .running, .cancelling:
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
        case .listening, .paused, .completed, .failed:
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
    let promptTitle: String?
    let promptDescription: String?
    let options: [AgentPermissionOption]
    var isResolving: Bool
}

/// A presentation-local tool identity that keeps replay and live provider IDs separate.
struct AgentToolPresentationID: Equatable, Hashable, Sendable {
    let source: AgentToolPresentationSource
    let providerID: String
}

/// The source that owns one presentation tool row.
enum AgentToolPresentationSource: Equatable, Hashable, Sendable {
    case live
    case restored(AgentRestorationToken)
}

/// The merged presentation state of a tool call and its partial updates.
struct AgentToolPresentation: Equatable, Sendable {
    let id: String
    let source: AgentToolPresentationSource
    var title: String
    var kind: AgentToolKind?
    var status: AgentToolCallStatus?
    var content: [String] = []
    var isSettled = false

    init(
        id: String,
        source: AgentToolPresentationSource = .live,
        title: String,
        kind: AgentToolKind?,
        status: AgentToolCallStatus?,
        content: [String] = [],
        isSettled: Bool = false
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.isSettled = isSettled
    }

    var presentationID: AgentToolPresentationID {
        AgentToolPresentationID(source: source, providerID: id)
    }

    var isWorking: Bool {
        !isSettled && (status == nil || status == .pending || status == .inProgress)
    }

    var isFinished: Bool {
        isSettled || status == .completed || status == .failed || status == .interrupted
    }
}

/// One generated result with identity stable across provider updates.
struct AgentArtifactPresentation: Equatable, Identifiable, Sendable {
    let id: UUID
    var artifact: AgentArtifact

    var embeddedByteCount: Int {
        switch artifact.payload {
        case .image(let data, _), .embeddedBlob(let data):
            data.count
        case .embeddedText(let text):
            text.utf8.count
        case .linked:
            0
        }
    }
}

/// A stable identity for heterogeneous reasoning and tool details.
enum AgentThinkingDetailID: Hashable, Sendable {
    case thought(UUID)
    case tool(AgentToolPresentationID)
}

/// One expandable detail retained inside a grouped thinking interval.
enum AgentThinkingDetail: Equatable, Identifiable, Sendable {
    case thought(AgentMessagePresentation)
    case tool(AgentToolPresentation)

    var id: AgentThinkingDetailID {
        switch self {
        case .thought(let message): .thought(message.id)
        case .tool(let tool): .tool(tool.presentationID)
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
    case spokenResponse
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
    let messageID: String?
    var text: String
    var disposition: AgentConversationInputDisposition?
    var contextSummary: AgentInputContextSummary?

    init(
        id: UUID,
        messageID: String? = nil,
        text: String,
        disposition: AgentConversationInputDisposition? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.text = text
        self.disposition = disposition
    }

    var transportPresentation: AgentUserMessageTransportPresentation? {
        disposition.map { disposition in
            let label = disposition.presentationLabel
            return AgentUserMessageTransportPresentation(
                caption: label,
                accessibilityLabel: "Delivery status",
                accessibilityValue: label)
        }
    }
}

/// Visible and spoken-accessibility copy for one locally submitted user input.
struct AgentUserMessageTransportPresentation: Equatable, Sendable {
    let caption: String
    let accessibilityLabel: String
    let accessibilityValue: String
}

extension AgentConversationInputDisposition {
    var presentationLabel: String {
        switch self {
        case .routing: "Routing…"
        case .injected: "Added to current turn"
        case .queued: "Queued for next turn"
        case .prompted: "Started as next turn"
        case .cancelled: "Cancelled before next turn"
        case .failed: "Delivery failed — say it again"
        }
    }
}

/// A stable identity for heterogeneous conversation timeline entries.
enum AgentRunTimelineItemID: Hashable, Sendable {
    case omitted
    case historyBoundary
    case message(UUID)
    case userMessage(UUID)
    case thinking(UUID)
}

/// One response, user message, thinking group, or bounded-omission marker.
enum AgentRunTimelineItem: Equatable, Identifiable, Sendable {
    case omitted
    case historyBoundary
    case message(AgentMessagePresentation)
    case userMessage(AgentUserMessagePresentation)
    case thinking(AgentThinkingPresentation)

    var id: AgentRunTimelineItemID {
        switch self {
        case .omitted: .omitted
        case .historyBoundary: .historyBoundary
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
    let profileName: String
    let profileIcon: ProfileIcon
    let accent: WakeProfileAccent
    let prompt: String
    let providerName: String
    let phase: AgentRunPhase
    let voiceInput: String
    let output: String
    let spokenOutput: String
    let timeline: [AgentRunTimelineItem]
    let diagnostics: String
    let plan: [AgentPlanEntry]
    let tools: [AgentToolPresentation]
    let permissions: [AgentPermissionPresentation]
    let notices: [String]
    let elapsedSeconds: Int
    let evictedToolCount: UInt64
    let ignoredToolUpdateCount: UInt64
    let artifacts: [AgentArtifactPresentation]
    let omittedArtifactCount: UInt64
    let backgroundTasks: [AgentBackgroundTaskPresentation]
    let ignoredBackgroundTaskCount: UInt64
    let promptContext: AgentInputContextSummary?

    var hasActiveBackgroundTasks: Bool {
        backgroundTasks.contains(where: \.isActive)
    }

    var canCloseOrDelete: Bool { !hasActiveBackgroundTasks }

    init(
        runID: UUID,
        profileID: UUID,
        profileName: String,
        profileIcon: ProfileIcon,
        accent: WakeProfileAccent,
        prompt: String,
        providerName: String,
        phase: AgentRunPhase,
        voiceInput: String,
        output: String,
        spokenOutput: String = "",
        timeline: [AgentRunTimelineItem],
        diagnostics: String,
        plan: [AgentPlanEntry],
        tools: [AgentToolPresentation],
        permissions: [AgentPermissionPresentation],
        notices: [String],
        elapsedSeconds: Int,
        evictedToolCount: UInt64,
        ignoredToolUpdateCount: UInt64,
        artifacts: [AgentArtifactPresentation] = [],
        omittedArtifactCount: UInt64 = 0,
        backgroundTasks: [AgentBackgroundTaskPresentation] = [],
        ignoredBackgroundTaskCount: UInt64 = 0,
        promptContext: AgentInputContextSummary? = nil)
    {
        self.runID = runID
        self.profileID = profileID
        self.profileName = profileName
        self.profileIcon = profileIcon
        self.accent = accent
        self.prompt = prompt
        self.promptContext = promptContext
        self.providerName = providerName
        self.phase = phase
        self.voiceInput = voiceInput
        self.output = output
        self.spokenOutput = spokenOutput
        self.timeline = timeline
        self.diagnostics = diagnostics
        self.plan = plan
        self.tools = tools
        self.permissions = permissions
        self.notices = notices
        self.elapsedSeconds = elapsedSeconds
        self.evictedToolCount = evictedToolCount
        self.ignoredToolUpdateCount = ignoredToolUpdateCount
        self.artifacts = artifacts
        self.omittedArtifactCount = omittedArtifactCount
        self.backgroundTasks = backgroundTasks
        self.ignoredBackgroundTaskCount = ignoredBackgroundTaskCount
    }

    /// A plain-text export containing only the retained request, response, and diagnostics.
    var copyText: String {
        var sections = ["Request\n\(prompt)"]
        if !output.isEmpty {
            sections.append("Response\n\(output)")
        }
        if !spokenOutput.isEmpty {
            sections.append("Spoken response\n\(spokenOutput)")
        }
        if !artifacts.isEmpty {
            let lines = artifacts.map { result in
                result.artifact.uri.map { "- \(result.artifact.name) — \($0)" }
                    ?? "- \(result.artifact.name)"
            }
            sections.append("Results\n" + lines.joined(separator: "\n"))
        }
        if !diagnostics.isEmpty {
            sections.append("Diagnostics\n\(diagnostics)")
        }
        return sections.joined(separator: "\n\n")
    }
}

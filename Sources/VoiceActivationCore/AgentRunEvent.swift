// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

public enum AgentToolKind: String, Codable, Equatable, Sendable {
    case read
    case edit
    case delete
    case move
    case search
    case execute
    case think
    case fetch
    case switchMode = "switch_mode"
    case other
}

public enum AgentToolCallStatus: String, Codable, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
}

public struct AgentToolCall: Equatable, Sendable {
    public let id: String
    public let title: String
    public let kind: AgentToolKind?
    public let status: AgentToolCallStatus?

    public init(
        id: String,
        title: String,
        kind: AgentToolKind? = nil,
        status: AgentToolCallStatus? = nil)
    {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
    }
}

public struct AgentToolCallUpdate: Equatable, Sendable {
    public let id: String
    public let title: String?
    public let kind: AgentToolKind?
    public let status: AgentToolCallStatus?

    public init(
        id: String,
        title: String? = nil,
        kind: AgentToolKind? = nil,
        status: AgentToolCallStatus? = nil)
    {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
    }
}

public enum AgentPlanPriority: String, Codable, Equatable, Sendable {
    case high
    case medium
    case low
}

public enum AgentPlanStatus: String, Codable, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

public struct AgentPlanEntry: Equatable, Sendable {
    public let content: String
    public let priority: AgentPlanPriority
    public let status: AgentPlanStatus

    public init(content: String, priority: AgentPlanPriority, status: AgentPlanStatus) {
        self.content = content
        self.priority = priority
        self.status = status
    }
}

public enum AgentPermissionOptionKind: String, Codable, Equatable, Sendable {
    case allowOnce = "allow_once"
    case allowAlways = "allow_always"
    case rejectOnce = "reject_once"
    case rejectAlways = "reject_always"
}

public struct AgentPermissionOption: Equatable, Sendable {
    public let id: String
    public let label: String
    public let kind: AgentPermissionOptionKind

    public init(id: String, label: String, kind: AgentPermissionOptionKind) {
        self.id = id
        self.label = label
        self.kind = kind
    }
}

public struct AgentPermissionRequest: Equatable, Sendable {
    public let turnToken: AgentTurnToken
    public let requestID: ACPRequestID
    public let toolCall: AgentToolCallUpdate
    public let options: [AgentPermissionOption]

    public init(
        turnToken: AgentTurnToken,
        requestID: ACPRequestID,
        toolCall: AgentToolCallUpdate,
        options: [AgentPermissionOption])
    {
        self.turnToken = turnToken
        self.requestID = requestID
        self.toolCall = toolCall
        self.options = options
    }
}

public enum AgentRunEventDeliveryNoticeKind: Equatable, Sendable {
    case outputTruncated
    case diagnosticTruncated
    case controlTruncated
}

public struct AgentRunEventDeliveryNotice: Equatable, Sendable {
    public let kind: AgentRunEventDeliveryNoticeKind
    public let discardedBytes: UInt64
    public let discardedEntries: UInt64

    public init(
        kind: AgentRunEventDeliveryNoticeKind,
        discardedBytes: UInt64,
        discardedEntries: UInt64)
    {
        self.kind = kind
        self.discardedBytes = discardedBytes
        self.discardedEntries = discardedEntries
    }
}

public enum AgentRunMetadataKind {
    public static let sessionRecovered = "session_recovered"
}

public enum AgentRunEvent: Equatable, Sendable {
    case connected(agentName: String, sessionID: String)
    case agentMessageDelta(messageID: String?, text: String)
    case thoughtDelta(messageID: String?, text: String)
    case toolCall(AgentToolCall)
    case toolCallUpdate(AgentToolCallUpdate)
    case plan([AgentPlanEntry])
    case metadata(kind: String, summary: String)
    case diagnostic(String)
    case permissionRequested(AgentPermissionRequest)
    case unknown(discriminator: String, summary: String)
    case deliveryNotice(AgentRunEventDeliveryNotice)
}

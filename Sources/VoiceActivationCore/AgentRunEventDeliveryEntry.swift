// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// The independent bounded channel used for streamed text backpressure.
enum AgentRunEventDeliveryTextKind: Equatable {
    case agentMessage(String?)
    case thought(String?)
    case diagnostic
}

/// A normalized queue entry with explicit byte cost and delivery criticality.
struct AgentRunEventDeliveryEntry {
    private var storedEvent: AgentRunEvent?
    private var textKind: AgentRunEventDeliveryTextKind?
    private var textBuffer: AgentRunEventDeliveryTextBuffer?
    private(set) var outputBytes: Int
    private(set) var diagnosticBytes: Int
    private(set) var controlBytes: Int

    var event: AgentRunEvent {
        if let storedEvent {
            return storedEvent
        }
        guard let textKind, let textBuffer else {
            preconditionFailure("A delivery entry must contain an event or text.")
        }
        return switch textKind {
        case let .agentMessage(messageID):
            .agentMessageDelta(messageID: messageID, text: textBuffer.value)
        case let .thought(messageID):
            .thoughtDelta(messageID: messageID, text: textBuffer.value)
        case .diagnostic:
            .diagnostic(textBuffer.value)
        }
    }

    var noticeKind: AgentRunEventDeliveryNoticeKind? {
        guard case let .deliveryNotice(notice) = storedEvent else {
            return nil
        }
        return notice.kind
    }

    init(event: AgentRunEvent) {
        storedEvent = event
        textKind = nil
        textBuffer = nil
        outputBytes = 0
        diagnosticBytes = 0
        controlBytes = Self.controlByteCount(for: event)
    }

    init(notice: AgentRunEventDeliveryNotice) {
        self.init(event: .deliveryNotice(notice))
    }

    init(textKind: AgentRunEventDeliveryTextKind, buffer: AgentRunEventDeliveryTextBuffer) {
        storedEvent = nil
        self.textKind = textKind
        textBuffer = buffer
        switch textKind {
        case let .agentMessage(messageID), let .thought(messageID):
            outputBytes = buffer.count
            diagnosticBytes = 0
            controlBytes = messageID?.utf8.count ?? 0
        case .diagnostic:
            outputBytes = 0
            diagnosticBytes = buffer.count
            controlBytes = 0
        }
    }

    func canCoalesce(with other: AgentRunEventDeliveryEntry) -> Bool {
        textKind != nil && textKind == other.textKind
    }

    mutating func appendText(from other: AgentRunEventDeliveryEntry) -> Int {
        guard let kind = textKind,
              let otherBuffer = other.textBuffer,
              kind == other.textKind
        else {
            preconditionFailure("Only compatible text entries may coalesce.")
        }
        let discarded = textBuffer!.append(otherBuffer.value)
        switch kind {
        case .agentMessage, .thought:
            outputBytes = textBuffer!.count
        case .diagnostic:
            diagnosticBytes = textBuffer!.count
        }
        return discarded
    }

    mutating func discardTextPrefix(atLeast byteCount: Int) -> Int {
        guard let kind = textKind, textBuffer != nil else {
            preconditionFailure("Only text entries have discardable prefixes.")
        }
        let discarded = textBuffer!.discardPrefix(atLeast: byteCount)
        switch kind {
        case .agentMessage, .thought:
            outputBytes = textBuffer!.count
        case .diagnostic:
            diagnosticBytes = textBuffer!.count
        }
        return discarded
    }

    mutating func addNoticeCounts(bytes: UInt64, entries: UInt64) {
        guard case let .deliveryNotice(notice) = storedEvent else {
            preconditionFailure("Only notices carry discard counts.")
        }
        storedEvent = .deliveryNotice(AgentRunEventDeliveryNotice(
            kind: notice.kind,
            discardedBytes: saturatingAdd(notice.discardedBytes, bytes),
            discardedEntries: saturatingAdd(notice.discardedEntries, entries)))
    }

    static func controlByteCount(for event: AgentRunEvent) -> Int {
        switch event {
        case let .connected(agentName, sessionID):
            return agentName.utf8.count + sessionID.utf8.count
        case let .agentMessageDelta(messageID, _), let .thoughtDelta(messageID, _):
            return messageID?.utf8.count ?? 0
        case let .toolCall(toolCall):
            return toolCall.id.utf8.count + toolCall.title.utf8.count
        case let .toolCallUpdate(update):
            return update.id.utf8.count + (update.title?.utf8.count ?? 0)
        case let .plan(entries):
            return entries.reduce(0) { saturatingAdd($0, $1.content.utf8.count) }
        case let .metadata(kind, summary):
            return kind.utf8.count + summary.utf8.count
        case .diagnostic:
            return 0
        case let .permissionRequested(request):
            var count = request.toolCall.id.utf8.count + (request.toolCall.title?.utf8.count ?? 0)
            if case let .string(id) = request.requestID {
                count = saturatingAdd(count, id.utf8.count)
            }
            for option in request.options {
                count = saturatingAdd(count, option.id.utf8.count)
                count = saturatingAdd(count, option.label.utf8.count)
            }
            return count
        case let .unknown(discriminator, summary):
            return discriminator.utf8.count + summary.utf8.count
        case .deliveryNotice:
            return 0
        }
    }
}

/// Coalesces adjacent token deltas while preserving UTF-8 bounds and message identity.
struct AgentRunEventDeliveryTextBuffer {
    private var storage: Data
    private var head: Int
    private let maximumBytes: Int
    let discardedOnInitialization: Int

    var count: Int {
        storage.count - head
    }

    var value: String {
        String(decoding: storage[head...], as: UTF8.self)
    }

    init(_ value: String, maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        let data = Data(value.utf8)
        if data.count <= maximumBytes {
            storage = data
            head = 0
            discardedOnInitialization = 0
        } else {
            let start = utf8SuffixStart(in: data, maximumBytes: maximumBytes)
            storage = Data(data[start...])
            head = 0
            discardedOnInitialization = start
        }
    }

    mutating func append(_ value: String) -> Int {
        let data = Data(value.utf8)
        guard !data.isEmpty else {
            return 0
        }
        if data.count >= maximumBytes {
            let previousCount = count
            let start = utf8SuffixStart(in: data, maximumBytes: maximumBytes)
            storage = Data(data[start...])
            head = 0
            return saturatingAdd(previousCount, start)
        }

        compactIfNeeded(forAdditionalBytes: data.count)
        storage.append(data)
        guard count > maximumBytes else {
            return 0
        }
        return discardPrefix(atLeast: count - maximumBytes)
    }

    mutating func discardPrefix(atLeast byteCount: Int) -> Int {
        guard byteCount > 0 else {
            return 0
        }
        var newHead = min(head + byteCount, storage.count)
        while newHead < storage.count, isUTF8Continuation(storage[newHead]) {
            newHead += 1
        }
        let discarded = newHead - head
        head = newHead
        compactIfNeeded(forAdditionalBytes: 0)
        return discarded
    }

    private mutating func compactIfNeeded(forAdditionalBytes additionalBytes: Int) {
        guard head > 0,
              head >= 64 * 1_024 || storage.count + additionalBytes > maximumBytes * 2
        else {
            return
        }
        storage.removeSubrange(0..<head)
        head = 0
    }
}

/// A safely truncated control string whose original byte loss remains observable.
struct BoundedControlText {
    let value: String
    let discardedBytes: Int
}

func boundedPrefix(_ value: String, maximumBytes: Int) -> BoundedControlText {
    let data = Data(value.utf8)
    guard data.count > maximumBytes else {
        return BoundedControlText(value: value, discardedBytes: 0)
    }
    var end = maximumBytes
    while end > 0, end < data.count, isUTF8Continuation(data[end]) {
        end -= 1
    }
    return BoundedControlText(
        value: String(decoding: data[..<end], as: UTF8.self),
        discardedBytes: data.count - end)
}

func utf8SuffixStart(in data: Data, maximumBytes: Int) -> Int {
    var start = max(0, data.count - maximumBytes)
    while start < data.count, isUTF8Continuation(data[start]) {
        start += 1
    }
    return start
}

func isUTF8Continuation(_ byte: UInt8) -> Bool {
    byte & 0xC0 == 0x80
}

func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : result
}

func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : result
}

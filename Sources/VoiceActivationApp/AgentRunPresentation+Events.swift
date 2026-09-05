// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import VoiceActivationCore

extension AgentRunPresentation {
    func apply(_ event: AgentRunEvent) {
        switch event {
        case .connected(let agentName, _):
            providerName = agentName
        case .agentMessageDelta(let messageID, let text):
            if needsResponseSeparator, !text.isEmpty {
                outputBuffer.append("\n\n")
                needsResponseSeparator = false
            }
            outputBuffer.append(text)
            settleActiveThinkingGroup()
            appendResponseMessage(text, messageID: messageID)
        case .thoughtDelta(let messageID, let text):
            appendThinkingMessage(text, messageID: messageID)
        case .toolCall(let tool):
            upsertTool(
                AgentToolPresentation(
                    id: tool.id,
                    title: tool.title,
                    kind: tool.kind,
                    status: tool.status))
        case .toolCallUpdate(let update):
            updateTool(update)
        case .plan(let entries):
            plan = entries
        case .metadata(let kind, let summary):
            if kind == AgentRunMetadataKind.sessionRecovered {
                appendNotice(summary)
            } else {
                diagnosticBuffer.append("[\(kind)] \(summary)\n")
            }
        case .diagnostic(let message):
            diagnosticBuffer.append(message)
            if !message.hasSuffix("\n") {
                diagnosticBuffer.append("\n")
            }
        case .permissionRequested(let request):
            let key = AgentPermissionKey(
                turnToken: request.turnToken,
                requestID: request.requestID)
            guard !permissions.contains(where: { $0.key == key }) else { return }
            permissions.append(
                AgentPermissionPresentation(
                    key: key,
                    toolTitle: request.toolCall.title ?? "Agent action",
                    options: request.options,
                    isResolving: false))
        case .unknown(let discriminator, let summary):
            diagnosticBuffer.append("[\(discriminator)] \(summary)\n")
        case .deliveryNotice(let notice):
            appendNotice(noticeDescription(notice))
        }
    }

    func appendNotice(_ message: String) {
        guard notices.last != message else { return }
        notices.append(message)
        if notices.count > 16 {
            notices.remove(at: notices.startIndex)
        }
    }

    func upsertTool(_ tool: AgentToolPresentation) {
        if let index = tools.firstIndex(where: { $0.id == tool.id }) {
            tools[index] = tool
            updateTimelineTool(tool)
            return
        }
        if tools.count == Self.maximumTools {
            let removedTool = tools.remove(at: tools.startIndex)
            if removeTimelineTool(id: removedTool.id) {
                markTimelineOmitted()
            }
            evictedToolCount = saturatingIncrement(evictedToolCount)
        }
        tools.append(tool)
        appendThinkingDetail(.tool(tool))
        enforceTimelineBounds()
    }

    func updateTool(_ update: AgentToolCallUpdate) {
        guard let index = tools.firstIndex(where: { $0.id == update.id }) else {
            ignoredToolUpdateCount = saturatingIncrement(ignoredToolUpdateCount)
            return
        }
        if let title = update.title {
            tools[index].title = title
        }
        if let kind = update.kind {
            tools[index].kind = kind
        }
        if let status = update.status {
            tools[index].status = status
        }
        updateTimelineTool(tools[index])
    }

    func settleTools() {
        for index in tools.indices where tools[index].isWorking {
            tools[index].isSettled = true
            updateTimelineTool(tools[index])
        }
        settleActiveThinkingGroup()
    }

    func appendResponseMessage(_ text: String, messageID: String?) {
        guard !text.isEmpty else { return }
        if case .message(var message) = timeline.last,
            message.kind == .response,
            message.messageID == messageID
        {
            message.text.append(text)
            timeline[timeline.index(before: timeline.endIndex)] = .message(message)
            enforceTimelineBounds()
            return
        }

        timeline.append(
            .message(
                AgentMessagePresentation(
                    id: UUID(),
                    messageID: messageID,
                    kind: .response,
                    text: text)))
        enforceTimelineBounds()
    }

    func appendThinkingMessage(_ text: String, messageID: String?) {
        guard !text.isEmpty else { return }
        var thinking = activeThinkingGroup()
        if case .thought(var message) = thinking.details.last,
            message.messageID == messageID
        {
            message.text.append(text)
            thinking.details[thinking.details.index(before: thinking.details.endIndex)] =
                .thought(message)
            replaceActiveThinkingGroup(with: thinking)
        } else {
            appendThinkingDetail(
                .thought(
                    AgentMessagePresentation(
                        id: UUID(),
                        messageID: messageID,
                        kind: .thought,
                        text: text)))
        }
        enforceTimelineBounds()
    }

    func appendThinkingDetail(_ detail: AgentThinkingDetail) {
        var thinking = activeThinkingGroup()
        if thinking.details.count == Self.maximumThinkingDetailsPerGroup {
            thinking.details.removeFirst()
            thinking.omittedDetailCount = saturatingIncrement(thinking.omittedDetailCount)
        }
        thinking.details.append(detail)
        replaceActiveThinkingGroup(with: thinking)
    }

    func activeThinkingGroup() -> AgentThinkingPresentation {
        if case .thinking(let thinking) = timeline.last, !thinking.isSettled {
            return thinking
        }
        let thinking = AgentThinkingPresentation(id: UUID(), details: [])
        timeline.append(.thinking(thinking))
        return thinking
    }

    func replaceActiveThinkingGroup(with thinking: AgentThinkingPresentation) {
        guard case .thinking = timeline.last else {
            preconditionFailure("The active thinking group must be the final timeline item.")
        }
        timeline[timeline.index(before: timeline.endIndex)] = .thinking(thinking)
    }

    func settleActiveThinkingGroup() {
        guard case .thinking(var thinking) = timeline.last, !thinking.isSettled else { return }
        guard !thinking.details.isEmpty else {
            timeline.removeLast()
            return
        }
        thinking.isSettled = true
        timeline[timeline.index(before: timeline.endIndex)] = .thinking(thinking)
    }

    func updateTimelineTool(_ tool: AgentToolPresentation) {
        for timelineIndex in timeline.indices {
            guard case .thinking(var thinking) = timeline[timelineIndex],
                let detailIndex = thinking.details.firstIndex(where: { detail in
                    guard case .tool(let candidate) = detail else { return false }
                    return candidate.id == tool.id
                })
            else { continue }
            thinking.details[detailIndex] = .tool(tool)
            timeline[timelineIndex] = .thinking(thinking)
            return
        }
    }

    @discardableResult
    func removeTimelineTool(id: String) -> Bool {
        for timelineIndex in timeline.indices {
            guard case .thinking(var thinking) = timeline[timelineIndex],
                let detailIndex = thinking.details.firstIndex(where: { detail in
                    guard case .tool(let tool) = detail else { return false }
                    return tool.id == id
                })
            else { continue }
            thinking.details.remove(at: detailIndex)
            thinking.omittedDetailCount = saturatingIncrement(thinking.omittedDetailCount)
            timeline[timelineIndex] = .thinking(thinking)
            return true
        }
        return false
    }

    func enforceTimelineBounds() {
        var retainedTextBytes = timelineTextByteCount
        while retainedTextBytes > Self.maximumTimelineTextBytes,
            let index = timeline.firstIndex(where: \AgentRunTimelineItem.containsText)
        {
            let originalByteCount = timeline[index].text.utf8.count
            let excessByteCount = retainedTextBytes - Self.maximumTimelineTextBytes
            if originalByteCount <= excessByteCount {
                timeline.remove(at: index)
                retainedTextBytes -= originalByteCount
            } else {
                timeline[index] = timeline[index].droppingTextPrefix(
                    atLeast: excessByteCount,
                    using: droppingUTF8Prefix)
                retainedTextBytes -= originalByteCount - timeline[index].text.utf8.count
            }
            markTimelineOmitted()
        }

        if timelineHasOmittedActivity,
            !timeline.contains(where: { item in
                if case .omitted = item { return true }
                return false
            })
        {
            timeline.insert(.omitted, at: timeline.startIndex)
        }

        while timeline.count > Self.maximumTimelineItems,
            let index = timeline.firstIndex(where: { item in
                if case .omitted = item { return false }
                return true
            })
        {
            timeline.remove(at: index)
            markTimelineOmitted()
        }
    }

    var timelineTextByteCount: Int {
        timeline.reduce(into: 0) { count, item in
            guard item.containsText else { return }
            let byteCount = item.text.utf8.count
            count = count > Int.max - byteCount ? Int.max : count + byteCount
        }
    }

    func markTimelineOmitted() {
        timelineHasOmittedActivity = true
        guard
            !timeline.contains(where: { item in
                if case .omitted = item { return true }
                return false
            })
        else { return }
        timeline.insert(.omitted, at: timeline.startIndex)
    }

    func droppingUTF8Prefix(_ text: String, atLeast byteCount: Int) -> String {
        let data = Data(text.utf8)
        var retainedStart = min(max(0, byteCount), data.count)
        while retainedStart < data.count, data[retainedStart] & 0xC0 == 0x80 {
            retainedStart += 1
        }
        return String(decoding: data[retainedStart...], as: UTF8.self)
    }

}

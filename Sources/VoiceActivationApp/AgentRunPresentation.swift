// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import VoiceActivationCore

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
}

struct AgentPermissionKey: Hashable, Sendable {
    let turnToken: AgentTurnToken
    let requestID: ACPRequestID
}

struct AgentPermissionPresentation: Equatable, Identifiable, Sendable {
    var id: AgentPermissionKey { key }

    let key: AgentPermissionKey
    let toolTitle: String
    let options: [AgentPermissionOption]
    var isResolving: Bool
}

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

enum AgentThinkingDetailID: Hashable, Sendable {
    case thought(UUID)
    case tool(String)
}

enum AgentThinkingDetail: Equatable, Identifiable, Sendable {
    case thought(AgentMessagePresentation)
    case tool(AgentToolPresentation)

    var id: AgentThinkingDetailID {
        switch self {
        case let .thought(message): .thought(message.id)
        case let .tool(tool): .tool(tool.id)
        }
    }
}

struct AgentThinkingPresentation: Equatable, Identifiable, Sendable {
    let id: UUID
    var details: [AgentThinkingDetail]
    var omittedDetailCount: UInt64 = 0
    var isSettled = false

    var isWorking: Bool { !isSettled }

    var hasFailedTool: Bool {
        details.contains { detail in
            guard case let .tool(tool) = detail else { return false }
            return tool.status == .failed
        }
    }
}

enum AgentMessagePresentationKind: Equatable, Sendable {
    case response
    case thought
}

struct AgentMessagePresentation: Equatable, Identifiable, Sendable {
    let id: UUID
    let messageID: String?
    let kind: AgentMessagePresentationKind
    var text: String
}

struct AgentUserMessagePresentation: Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
}

enum AgentRunTimelineItemID: Hashable, Sendable {
    case omitted
    case message(UUID)
    case userMessage(UUID)
    case thinking(UUID)
}

enum AgentRunTimelineItem: Equatable, Identifiable, Sendable {
    case omitted
    case message(AgentMessagePresentation)
    case userMessage(AgentUserMessagePresentation)
    case thinking(AgentThinkingPresentation)

    var id: AgentRunTimelineItemID {
        switch self {
        case .omitted: .omitted
        case let .message(message): .message(message.id)
        case let .userMessage(message): .userMessage(message.id)
        case let .thinking(thinking): .thinking(thinking.id)
        }
    }
}

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

@MainActor
final class AgentRunPresentation {
    static let maximumOutputBytes = 512 * 1_024
    static let maximumDiagnosticBytes = 16 * 1_024
    static let maximumTools = 32
    static let maximumTimelineTextBytes = 64 * 1_024
    static let maximumTimelineItems = 256
    static let maximumThinkingDetailsPerGroup = 128
    static let publicationInterval = Duration.milliseconds(50)

    var onPublication: ((AgentRunSnapshot) -> Void)?

    var snapshot: AgentRunSnapshot? {
        guard let runID, let profileID, let accent, let prompt, let providerName, let phase else {
            return nil
        }
        return AgentRunSnapshot(
            runID: runID,
            profileID: profileID,
            accent: accent,
            prompt: prompt,
            providerName: providerName,
            phase: phase,
            voiceInput: voiceInput,
            output: outputBuffer.value,
            timeline: timeline,
            diagnostics: diagnosticBuffer.value,
            plan: plan,
            tools: tools,
            permissions: permissions,
            notices: notices,
            elapsedSeconds: elapsedSeconds,
            evictedToolCount: evictedToolCount,
            ignoredToolUpdateCount: ignoredToolUpdateCount)
    }

    private let startsElapsedTimer: Bool
    private let clock = ContinuousClock()
    private var runID: UUID?
    private var profileID: UUID?
    private var accent: WakeProfileAccent?
    private var prompt: String?
    private var providerName: String?
    private var phase: AgentRunPhase?
    private var voiceInput = ""
    private var needsResponseSeparator = false
    private var outputBuffer = AgentRunBoundedTextBuffer(
        maximumBytes: maximumOutputBytes,
        marker: "… earlier output omitted …\n")
    private var diagnosticBuffer = AgentRunBoundedTextBuffer(
        maximumBytes: maximumDiagnosticBytes,
        marker: "… earlier diagnostics omitted …\n")
    private var plan: [AgentPlanEntry] = []
    private var tools: [AgentToolPresentation] = []
    private var timeline: [AgentRunTimelineItem] = []
    private var timelineHasOmittedActivity = false
    private var permissions: [AgentPermissionPresentation] = []
    private var notices: [String] = []
    private var elapsedSeconds = 0
    private var evictedToolCount: UInt64 = 0
    private var ignoredToolUpdateCount: UInt64 = 0
    private var startedAt: ContinuousClock.Instant?
    private var lastPublicationAt: ContinuousClock.Instant?
    private var publicationIsPending = false
    private var trailingPublicationTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?

    init(startsElapsedTimer: Bool = true) {
        self.startsElapsedTimer = startsElapsedTimer
    }

    func start(runID: UUID, profile: WakeProfile, prompt: String) {
        cancelTimers()
        self.runID = runID
        profileID = profile.id
        accent = profile.accent
        self.prompt = prompt
        if case let .agent(configuration) = profile.action {
            providerName = configuration.displayName
        } else {
            providerName = "Agent"
        }
        phase = .running
        voiceInput = ""
        needsResponseSeparator = false
        outputBuffer.removeAll()
        diagnosticBuffer.removeAll()
        plan = []
        tools = []
        timeline = []
        _ = activeThinkingGroup()
        timelineHasOmittedActivity = false
        permissions = []
        notices = []
        elapsedSeconds = 0
        evictedToolCount = 0
        ignoredToolUpdateCount = 0
        startedAt = clock.now
        lastPublicationAt = nil
        publicationIsPending = false
        publishNow()
        if startsElapsedTimer {
            startElapsedTimer(runID: runID)
        }
    }

    func receive(runID: UUID, event: AgentRunEvent) {
        guard self.runID == runID, phase?.isTerminal == false else { return }
        if event.isTokenDelta {
            apply(event)
            publishTokenUpdate(runID: runID)
            return
        }

        flushPendingPublication()
        apply(event)
        publishNow()
    }

    func submitFollowUp(runID: UUID, prompt: String) {
        guard self.runID == runID, phase?.isTerminal == false else { return }
        flushPendingPublication()
        settleActiveThinkingGroup()
        timeline.append(.userMessage(AgentUserMessagePresentation(id: UUID(), text: prompt)))
        voiceInput = ""
        enforceTimelineBounds()
        publishNow()
    }

    func receiveNotice(runID: UUID, message: String) {
        guard self.runID == runID, phase?.isTerminal == false, !message.isEmpty else { return }
        flushPendingPublication()
        appendNotice(message)
        publishNow()
    }

    func beginTurn(runID: UUID) {
        guard self.runID == runID, phase?.isTerminal == false else { return }
        flushPendingPublication()
        phase = .running
        needsResponseSeparator = !outputBuffer.value.isEmpty
        plan = []
        permissions = []
        voiceInput = ""
        _ = activeThinkingGroup()
        publishNow()
    }

    func completeTurn(runID: UUID, result _: AgentRunResult) {
        guard self.runID == runID, phase?.isTerminal == false else { return }
        flushPendingPublication()
        settleTools()
        phase = .listening
        permissions = []
        voiceInput = ""
        publishNow()
    }

    func interruptTurn(runID: UUID, message: String) {
        guard self.runID == runID, phase?.isTerminal == false else { return }
        flushPendingPublication()
        settleTools()
        phase = .listening
        permissions = []
        voiceInput = ""
        diagnosticBuffer.append("[turn interrupted] \(message)\n")
        appendNotice(
            "The provider disconnected after producing output. "
                + "Your next message starts a fresh session.")
        publishNow()
    }

    func updateVoiceInput(runID: UUID, transcript: String) {
        guard self.runID == runID, phase?.isTerminal == false, voiceInput != transcript else {
            return
        }
        voiceInput = transcript
        publishNow()
    }

    @discardableResult
    func beginPermissionResolution(runID: UUID, key: AgentPermissionKey) -> Bool {
        guard self.runID == runID,
              phase == .running,
              let index = permissions.firstIndex(where: { $0.key == key }),
              !permissions[index].isResolving
        else { return false }

        permissions.remove(at: index)
        flushPendingPublication()
        publishNow()
        return true
    }

    @discardableResult
    func beginCancellation(runID: UUID) -> Bool {
        guard self.runID == runID, phase == .running else { return false }
        flushPendingPublication()
        phase = .cancelling
        publishNow()
        return true
    }

    func complete(runID: UUID, result: AgentRunResult) {
        guard self.runID == runID, phase?.isTerminal == false else { return }
        flushPendingPublication()
        settleTools()
        phase = .completed(result.stopReason)
        permissions = []
        stopRuntimeTimers()
        publishNow()
    }

    func fail(runID: UUID, message: String) {
        guard self.runID == runID, phase?.isTerminal == false else { return }
        flushPendingPublication()
        settleTools()
        phase = .failed(message)
        permissions = []
        stopRuntimeTimers()
        publishNow()
    }

    func close(runID: UUID) {
        guard self.runID == runID else { return }
        stopRuntimeTimers()
    }

    func discard(runID: UUID) {
        guard self.runID == runID else { return }
        clearRetainedRun()
    }

    func shutdown() {
        clearRetainedRun()
    }

    private func clearRetainedRun() {
        cancelTimers()
        runID = nil
        profileID = nil
        accent = nil
        prompt = nil
        providerName = nil
        phase = nil
        voiceInput = ""
        needsResponseSeparator = false
        outputBuffer.removeAll(keepingCapacity: false)
        diagnosticBuffer.removeAll(keepingCapacity: false)
        plan.removeAll(keepingCapacity: false)
        tools.removeAll(keepingCapacity: false)
        timeline.removeAll(keepingCapacity: false)
        timelineHasOmittedActivity = false
        permissions.removeAll(keepingCapacity: false)
        notices.removeAll(keepingCapacity: false)
        elapsedSeconds = 0
        evictedToolCount = 0
        ignoredToolUpdateCount = 0
    }

    private func apply(_ event: AgentRunEvent) {
        switch event {
        case let .connected(agentName, _):
            providerName = agentName
        case let .agentMessageDelta(messageID, text):
            if needsResponseSeparator, !text.isEmpty {
                outputBuffer.append("\n\n")
                needsResponseSeparator = false
            }
            outputBuffer.append(text)
            settleActiveThinkingGroup()
            appendResponseMessage(text, messageID: messageID)
        case let .thoughtDelta(messageID, text):
            appendThinkingMessage(text, messageID: messageID)
        case let .toolCall(tool):
            upsertTool(AgentToolPresentation(
                id: tool.id,
                title: tool.title,
                kind: tool.kind,
                status: tool.status))
        case let .toolCallUpdate(update):
            updateTool(update)
        case let .plan(entries):
            plan = entries
        case let .metadata(kind, summary):
            if kind == AgentRunMetadataKind.sessionRecovered {
                appendNotice(summary)
            } else {
                diagnosticBuffer.append("[\(kind)] \(summary)\n")
            }
        case let .diagnostic(message):
            diagnosticBuffer.append(message)
            if !message.hasSuffix("\n") {
                diagnosticBuffer.append("\n")
            }
        case let .permissionRequested(request):
            let key = AgentPermissionKey(
                turnToken: request.turnToken,
                requestID: request.requestID)
            guard !permissions.contains(where: { $0.key == key }) else { return }
            permissions.append(AgentPermissionPresentation(
                key: key,
                toolTitle: request.toolCall.title ?? "Agent action",
                options: request.options,
                isResolving: false))
        case let .unknown(discriminator, summary):
            diagnosticBuffer.append("[\(discriminator)] \(summary)\n")
        case let .deliveryNotice(notice):
            appendNotice(noticeDescription(notice))
        }
    }

    private func appendNotice(_ message: String) {
        guard notices.last != message else { return }
        notices.append(message)
        if notices.count > 16 {
            notices.remove(at: notices.startIndex)
        }
    }

    private func upsertTool(_ tool: AgentToolPresentation) {
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

    private func updateTool(_ update: AgentToolCallUpdate) {
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

    private func settleTools() {
        for index in tools.indices where tools[index].isWorking {
            tools[index].isSettled = true
            updateTimelineTool(tools[index])
        }
        settleActiveThinkingGroup()
    }

    private func appendResponseMessage(_ text: String, messageID: String?) {
        guard !text.isEmpty else { return }
        if case var .message(message) = timeline.last,
           message.kind == .response,
           message.messageID == messageID
        {
            message.text.append(text)
            timeline[timeline.index(before: timeline.endIndex)] = .message(message)
            enforceTimelineBounds()
            return
        }

        timeline.append(.message(AgentMessagePresentation(
            id: UUID(),
            messageID: messageID,
            kind: .response,
            text: text)))
        enforceTimelineBounds()
    }

    private func appendThinkingMessage(_ text: String, messageID: String?) {
        guard !text.isEmpty else { return }
        var thinking = activeThinkingGroup()
        if case var .thought(message) = thinking.details.last,
           message.messageID == messageID
        {
            message.text.append(text)
            thinking.details[thinking.details.index(before: thinking.details.endIndex)] =
                .thought(message)
            replaceActiveThinkingGroup(with: thinking)
        } else {
            appendThinkingDetail(.thought(AgentMessagePresentation(
                id: UUID(),
                messageID: messageID,
                kind: .thought,
                text: text)))
        }
        enforceTimelineBounds()
    }

    private func appendThinkingDetail(_ detail: AgentThinkingDetail) {
        var thinking = activeThinkingGroup()
        if thinking.details.count == Self.maximumThinkingDetailsPerGroup {
            thinking.details.removeFirst()
            thinking.omittedDetailCount = saturatingIncrement(thinking.omittedDetailCount)
        }
        thinking.details.append(detail)
        replaceActiveThinkingGroup(with: thinking)
    }

    private func activeThinkingGroup() -> AgentThinkingPresentation {
        if case let .thinking(thinking) = timeline.last, !thinking.isSettled {
            return thinking
        }
        let thinking = AgentThinkingPresentation(id: UUID(), details: [])
        timeline.append(.thinking(thinking))
        return thinking
    }

    private func replaceActiveThinkingGroup(with thinking: AgentThinkingPresentation) {
        guard case .thinking = timeline.last else {
            preconditionFailure("The active thinking group must be the final timeline item.")
        }
        timeline[timeline.index(before: timeline.endIndex)] = .thinking(thinking)
    }

    private func settleActiveThinkingGroup() {
        guard case var .thinking(thinking) = timeline.last, !thinking.isSettled else { return }
        guard !thinking.details.isEmpty else {
            timeline.removeLast()
            return
        }
        thinking.isSettled = true
        timeline[timeline.index(before: timeline.endIndex)] = .thinking(thinking)
    }

    private func updateTimelineTool(_ tool: AgentToolPresentation) {
        for timelineIndex in timeline.indices {
            guard case var .thinking(thinking) = timeline[timelineIndex],
                  let detailIndex = thinking.details.firstIndex(where: { detail in
                      guard case let .tool(candidate) = detail else { return false }
                      return candidate.id == tool.id
                  })
            else { continue }
            thinking.details[detailIndex] = .tool(tool)
            timeline[timelineIndex] = .thinking(thinking)
            return
        }
    }

    @discardableResult
    private func removeTimelineTool(id: String) -> Bool {
        for timelineIndex in timeline.indices {
            guard case var .thinking(thinking) = timeline[timelineIndex],
                  let detailIndex = thinking.details.firstIndex(where: { detail in
                      guard case let .tool(tool) = detail else { return false }
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

    private func enforceTimelineBounds() {
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

    private var timelineTextByteCount: Int {
        timeline.reduce(into: 0) { count, item in
            guard item.containsText else { return }
            let byteCount = item.text.utf8.count
            count = count > Int.max - byteCount ? Int.max : count + byteCount
        }
    }

    private func markTimelineOmitted() {
        timelineHasOmittedActivity = true
        guard !timeline.contains(where: { item in
            if case .omitted = item { return true }
            return false
        }) else { return }
        timeline.insert(.omitted, at: timeline.startIndex)
    }

    private func droppingUTF8Prefix(_ text: String, atLeast byteCount: Int) -> String {
        let data = Data(text.utf8)
        var retainedStart = min(max(0, byteCount), data.count)
        while retainedStart < data.count, data[retainedStart] & 0xC0 == 0x80 {
            retainedStart += 1
        }
        return String(decoding: data[retainedStart...], as: UTF8.self)
    }

    private func publishTokenUpdate(runID: UUID) {
        let now = clock.now
        guard let lastPublicationAt else {
            publishNow()
            return
        }
        let deadline = lastPublicationAt.advanced(by: Self.publicationInterval)
        guard now < deadline else {
            publishNow()
            return
        }
        publicationIsPending = true
        guard trailingPublicationTask == nil else { return }
        let delay = now.duration(to: deadline)
        trailingPublicationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.runID == runID else { return }
            self.trailingPublicationTask = nil
            guard self.publicationIsPending else { return }
            self.publishNow()
        }
    }

    private func flushPendingPublication() {
        guard publicationIsPending else { return }
        trailingPublicationTask?.cancel()
        trailingPublicationTask = nil
        publishNow()
    }

    private func publishNow() {
        publicationIsPending = false
        lastPublicationAt = clock.now
        if let snapshot {
            onPublication?(snapshot)
        }
    }

    private func startElapsedTimer(runID: UUID) {
        elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.runID == runID else { return }
                self.elapsedSeconds = self.elapsedSeconds == Int.max
                    ? Int.max
                    : self.elapsedSeconds + 1
                self.publishNow()
            }
        }
    }

    private func stopRuntimeTimers() {
        trailingPublicationTask?.cancel()
        trailingPublicationTask = nil
        publicationIsPending = false
        elapsedTask?.cancel()
        elapsedTask = nil
    }

    private func cancelTimers() {
        stopRuntimeTimers()
        lastPublicationAt = nil
        startedAt = nil
    }

    private func noticeDescription(_ notice: AgentRunEventDeliveryNotice) -> String {
        let subject = switch notice.kind {
        case .outputTruncated: "Earlier streamed output"
        case .diagnosticTruncated: "Earlier diagnostics"
        case .controlTruncated: "Oversized event details"
        }
        return "\(subject) omitted (\(notice.discardedBytes) bytes, "
            + "\(notice.discardedEntries) entries)."
    }
}

private extension AgentRunEvent {
    var isTokenDelta: Bool {
        switch self {
        case .agentMessageDelta, .thoughtDelta:
            true
        default:
            false
        }
    }
}

private struct AgentRunBoundedTextBuffer {
    private let maximumBytes: Int
    private let marker: Data
    private var storage = Data()
    private var head = 0
    private(set) var discardedBytes: UInt64 = 0

    var value: String {
        guard discardedBytes > 0 else {
            return String(decoding: storage[head...], as: UTF8.self)
        }
        var rendered = marker
        rendered.append(storage[head...])
        return String(decoding: rendered, as: UTF8.self)
    }

    init(maximumBytes: Int, marker: String) {
        precondition(maximumBytes > marker.utf8.count)
        self.maximumBytes = maximumBytes
        self.marker = Data(marker.utf8)
    }

    mutating func append(_ text: String) {
        let data = Data(text.utf8)
        guard !data.isEmpty else { return }
        compactIfNeeded(additionalBytes: data.count)
        storage.append(data)
        let payloadLimit = maximumBytes - (discardedBytes > 0 ? marker.count : 0)
        if storage.count - head > payloadLimit {
            discardPrefix(atLeast: storage.count - head - (maximumBytes - marker.count))
        }
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        head = 0
        discardedBytes = 0
    }

    private mutating func discardPrefix(atLeast count: Int) {
        var newHead = min(storage.count, head + max(0, count))
        while newHead < storage.count, storage[newHead] & 0xC0 == 0x80 {
            newHead += 1
        }
        discardedBytes = saturatingAdd(discardedBytes, UInt64(newHead - head))
        head = newHead
        compactIfNeeded(additionalBytes: 0)
    }

    private mutating func compactIfNeeded(additionalBytes: Int) {
        guard head > 0,
              head >= 64 * 1_024 || storage.count + additionalBytes > maximumBytes * 2
        else { return }
        storage.removeSubrange(0..<head)
        head = 0
    }
}

private extension AgentRunTimelineItem {
    var containsText: Bool {
        switch self {
        case .message, .userMessage:
            true
        case let .thinking(thinking):
            thinking.details.contains { detail in
                guard case let .thought(message) = detail else { return false }
                return !message.text.isEmpty
            }
        case .omitted:
            false
        }
    }

    var text: String {
        switch self {
        case let .message(message):
            message.text
        case let .userMessage(message):
            message.text
        case let .thinking(thinking):
            thinking.details.reduce(into: "") { text, detail in
                guard case let .thought(message) = detail else { return }
                text.append(message.text)
            }
        case .omitted:
            ""
        }
    }

    func droppingTextPrefix(
        atLeast byteCount: Int,
        using transform: (String, Int) -> String) -> AgentRunTimelineItem
    {
        switch self {
        case var .message(message):
            message.text = transform(message.text, byteCount)
            return .message(message)
        case let .userMessage(message):
            return .userMessage(AgentUserMessagePresentation(
                id: message.id,
                text: transform(message.text, byteCount)))
        case var .thinking(thinking):
            var remainingBytes = byteCount
            var retainedDetails: [AgentThinkingDetail] = []
            for detail in thinking.details {
                guard case var .thought(message) = detail, remainingBytes > 0 else {
                    retainedDetails.append(detail)
                    continue
                }
                let originalByteCount = message.text.utf8.count
                if originalByteCount <= remainingBytes {
                    remainingBytes -= originalByteCount
                    thinking.omittedDetailCount = saturatingIncrement(
                        thinking.omittedDetailCount)
                    continue
                }
                message.text = transform(message.text, remainingBytes)
                remainingBytes = 0
                retainedDetails.append(.thought(message))
            }
            thinking.details = retainedDetails
            return .thinking(thinking)
        case .omitted:
            return self
        }
    }
}

private func saturatingIncrement(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? UInt64.max : value + 1
}

private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : result
}

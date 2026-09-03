import Foundation
import VoiceActivationCore

enum AgentRunPhase: Equatable, Sendable {
    case running
    case cancelling
    case completed(AgentStopReason)
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .completed, .failed:
            true
        case .running, .cancelling:
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
}

struct AgentRunSnapshot: Equatable, Sendable {
    let runID: UUID
    let profileID: UUID
    let accent: WakeProfileAccent
    let prompt: String
    let providerName: String
    let phase: AgentRunPhase
    let output: String
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
            output: outputBuffer.value,
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
    private var outputBuffer = AgentRunBoundedTextBuffer(
        maximumBytes: maximumOutputBytes,
        marker: "… earlier output omitted …\n")
    private var diagnosticBuffer = AgentRunBoundedTextBuffer(
        maximumBytes: maximumDiagnosticBytes,
        marker: "… earlier diagnostics omitted …\n")
    private var plan: [AgentPlanEntry] = []
    private var tools: [AgentToolPresentation] = []
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
        outputBuffer.removeAll()
        diagnosticBuffer.removeAll()
        plan = []
        tools = []
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

    @discardableResult
    func beginPermissionResolution(runID: UUID, key: AgentPermissionKey) -> Bool {
        guard self.runID == runID,
              phase == .running,
              let index = permissions.firstIndex(where: { $0.key == key }),
              !permissions[index].isResolving
        else { return false }

        permissions[index].isResolving = true
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
        phase = .completed(result.stopReason)
        permissions = []
        stopRuntimeTimers()
        publishNow()
    }

    func fail(runID: UUID, message: String) {
        guard self.runID == runID, phase?.isTerminal == false else { return }
        flushPendingPublication()
        phase = .failed(message)
        permissions = []
        stopRuntimeTimers()
        publishNow()
    }

    func close(runID: UUID) {
        guard self.runID == runID else { return }
        stopRuntimeTimers()
    }

    func shutdown() {
        cancelTimers()
        runID = nil
    }

    private func apply(_ event: AgentRunEvent) {
        switch event {
        case let .connected(agentName, _):
            providerName = agentName
        case let .agentMessageDelta(_, text):
            outputBuffer.append(text)
        case let .thoughtDelta(_, text):
            outputBuffer.append(text)
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
            diagnosticBuffer.append("[\(kind)] \(summary)\n")
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
            notices.append(noticeDescription(notice))
            if notices.count > 16 {
                notices.remove(at: notices.startIndex)
            }
        }
    }

    private func upsertTool(_ tool: AgentToolPresentation) {
        if let index = tools.firstIndex(where: { $0.id == tool.id }) {
            tools[index] = tool
            return
        }
        if tools.count == Self.maximumTools {
            tools.remove(at: tools.startIndex)
            evictedToolCount = saturatingIncrement(evictedToolCount)
        }
        tools.append(tool)
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

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
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

private func saturatingIncrement(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? UInt64.max : value + 1
}

private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : result
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

enum AgentRunEventDeliveryFinishMode: Sendable {
    case drain
    case discard
}

enum AgentRunEventDeliveryAdmission: Equatable, Sendable {
    case accepted
    case ignored
    case stopped
    case capacityExceeded
    case invalid
}

enum AgentRunEventDeliveryLifecycleState: Equatable, Sendable {
    case open
    case draining
    case discarded
}

struct AgentRunEventDeliverySnapshot: Equatable, Sendable {
    let state: AgentRunEventDeliveryLifecycleState
    let pendingOutputBytes: Int
    let pendingDiagnosticBytes: Int
    let pendingControlBytes: Int
    let pendingEntryCount: Int
    let discardedOutputBytes: UInt64
    let discardedOutputEntries: UInt64
    let discardedDiagnosticBytes: UInt64
}

final class AgentRunEventDelivery: @unchecked Sendable {
    static let maximumPendingOutputBytes = 512 * 1_024
    static let maximumPendingDiagnosticBytes = 16 * 1_024
    static let maximumPendingControlBytes = 512 * 1_024
    static let maximumPendingEntries = 256
    static let maximumOpaqueIdentifierBytes = 4 * 1_024
    static let maximumPermissionOptions = 64
    static let maximumPlanEntries = 64

    private let state: AgentRunEventDeliveryQueue
    private let completion: AgentRunEventDeliveryCompletion
    private var consumerTask: Task<Void, Never>!

    var snapshotForTesting: AgentRunEventDeliverySnapshot {
        state.snapshot
    }

    init(handler: @escaping @Sendable (AgentRunEvent) async -> Void) {
        let state = AgentRunEventDeliveryQueue()
        let completion = AgentRunEventDeliveryCompletion()
        self.state = state
        self.completion = completion
        consumerTask = Task {
            while let event = await state.next() {
                await handler(event)
            }
            completion.resolve()
        }
    }

    deinit {
        state.discard()
        consumerTask.cancel()
        completion.resolve()
    }

    @discardableResult
    func send(_ event: AgentRunEvent) -> AgentRunEventDeliveryAdmission {
        state.send(event)
    }

    func stopAdmission() {
        state.startDraining()
    }

    func finish(_ mode: AgentRunEventDeliveryFinishMode) async {
        switch mode {
        case .drain:
            state.startDraining()
            await completion.wait()
        case .discard:
            state.discard()
            consumerTask.cancel()
            completion.resolve()
        }
    }

    func waitForConsumerTerminationForTesting() async {
        _ = await consumerTask.result
    }
}

private final class AgentRunEventDeliveryCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isResolved = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func resolve() {
        var continuations: [CheckedContinuation<Void, Never>] = []
        lock.withLock {
            guard !isResolved else {
                return
            }
            isResolved = true
            continuations = waiters
            waiters.removeAll()
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            var shouldResume = false
            lock.withLock {
                if isResolved {
                    shouldResume = true
                } else {
                    waiters.append(continuation)
                }
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private final class AgentRunEventDeliveryQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var lifecycle = AgentRunEventDeliveryLifecycleState.open
    private var entries = AgentRunEventDeque()
    private var waiter: CheckedContinuation<AgentRunEvent?, Never>?
    private var pendingOutputBytes = 0
    private var pendingDiagnosticBytes = 0
    private var pendingControlBytes = 0
    private var discardedOutputBytes: UInt64 = 0
    private var discardedOutputEntries: UInt64 = 0
    private var discardedDiagnosticBytes: UInt64 = 0

    var snapshot: AgentRunEventDeliverySnapshot {
        lock.withLock {
            AgentRunEventDeliverySnapshot(
                state: lifecycle,
                pendingOutputBytes: pendingOutputBytes,
                pendingDiagnosticBytes: pendingDiagnosticBytes,
                pendingControlBytes: pendingControlBytes,
                pendingEntryCount: entries.count,
                discardedOutputBytes: discardedOutputBytes,
                discardedOutputEntries: discardedOutputEntries,
                discardedDiagnosticBytes: discardedDiagnosticBytes)
        }
    }

    func send(_ event: AgentRunEvent) -> AgentRunEventDeliveryAdmission {
        var continuation: CheckedContinuation<AgentRunEvent?, Never>?
        var immediateEvent: AgentRunEvent?
        let result = lock.withLock { () -> AgentRunEventDeliveryAdmission in
            guard lifecycle == .open else {
                return .stopped
            }

            let normalized: AgentRunEventNormalization
            do {
                normalized = try AgentRunEventNormalizer.normalize(event)
            } catch {
                lifecycle = .draining
                prepareFinishedWaiter(
                    continuation: &continuation,
                    immediateEvent: &immediateEvent)
                return .invalid
            }
            guard !normalized.entries.isEmpty else {
                return .ignored
            }

            if normalized.entries.count == 1,
               entries.lastCanCoalesce(with: normalized.entries[0])
            {
                let change = entries.coalesceLast(with: normalized.entries[0])
                pendingOutputBytes += change.outputByteDelta
                pendingDiagnosticBytes += change.diagnosticByteDelta
                if change.discardedBytes > 0 {
                    insertNotice(
                        at: entries.count - 1,
                        kind: change.noticeKind,
                        discardedBytes: UInt64(change.discardedBytes),
                        discardedEntries: 0)
                }
                precondition(enforceBounds())
                if waiter != nil, let entry = popFirst() {
                    continuation = waiter
                    waiter = nil
                    immediateEvent = entry.event
                }
                return .accepted
            }

            let savedEntries = entries
            let savedOutputBytes = pendingOutputBytes
            let savedDiagnosticBytes = pendingDiagnosticBytes
            let savedControlBytes = pendingControlBytes
            let savedDiscardedOutputBytes = discardedOutputBytes
            let savedDiscardedOutputEntries = discardedOutputEntries
            let savedDiscardedDiagnosticBytes = discardedDiagnosticBytes

            for entry in normalized.entries {
                append(entry)
            }
            guard enforceBounds() else {
                entries = savedEntries
                pendingOutputBytes = savedOutputBytes
                pendingDiagnosticBytes = savedDiagnosticBytes
                pendingControlBytes = savedControlBytes
                discardedOutputBytes = savedDiscardedOutputBytes
                discardedOutputEntries = savedDiscardedOutputEntries
                discardedDiagnosticBytes = savedDiscardedDiagnosticBytes
                lifecycle = .draining
                prepareFinishedWaiter(
                    continuation: &continuation,
                    immediateEvent: &immediateEvent)
                return .capacityExceeded
            }

            if waiter != nil, let entry = popFirst() {
                continuation = waiter
                waiter = nil
                immediateEvent = entry.event
            }
            return .accepted
        }
        continuation?.resume(returning: immediateEvent)
        return result
    }

    func startDraining() {
        var continuation: CheckedContinuation<AgentRunEvent?, Never>?
        lock.withLock {
            guard lifecycle == .open else {
                return
            }
            lifecycle = .draining
            if entries.isEmpty {
                continuation = waiter
                waiter = nil
            }
        }
        continuation?.resume(returning: nil)
    }

    func discard() {
        var continuation: CheckedContinuation<AgentRunEvent?, Never>?
        lock.withLock {
            guard lifecycle != .discarded else {
                return
            }
            lifecycle = .discarded
            entries.removeAll()
            pendingOutputBytes = 0
            pendingDiagnosticBytes = 0
            pendingControlBytes = 0
            continuation = waiter
            waiter = nil
        }
        continuation?.resume(returning: nil)
    }

    func next() async -> AgentRunEvent? {
        await withCheckedContinuation { continuation in
            var event: AgentRunEvent?
            var shouldResume = false
            lock.withLock {
                if let entry = popFirst() {
                    event = entry.event
                    shouldResume = true
                } else if lifecycle != .open {
                    shouldResume = true
                } else {
                    precondition(waiter == nil)
                    waiter = continuation
                }
            }
            if shouldResume {
                continuation.resume(returning: event)
            }
        }
    }

    private func prepareFinishedWaiter(
        continuation: inout CheckedContinuation<AgentRunEvent?, Never>?,
        immediateEvent: inout AgentRunEvent?)
    {
        guard entries.isEmpty else {
            return
        }
        continuation = waiter
        waiter = nil
        immediateEvent = nil
    }

    private func append(_ entry: AgentRunEventDeliveryEntry) {
        entries.append(entry)
        addCounters(for: entry)
    }

    private func enforceBounds() -> Bool {
        trimPayload(
            current: { pendingOutputBytes },
            maximum: AgentRunEventDelivery.maximumPendingOutputBytes,
            category: .outputTruncated)
        trimPayload(
            current: { pendingDiagnosticBytes },
            maximum: AgentRunEventDelivery.maximumPendingDiagnosticBytes,
            category: .diagnosticTruncated)

        while pendingControlBytes > AgentRunEventDelivery.maximumPendingControlBytes {
            guard let index = entries.firstIndex(where: { $0.outputBytes > 0 }) else {
                return false
            }
            discardWholeEntry(at: index, noticeKind: .outputTruncated)
        }

        while entries.count > AgentRunEventDelivery.maximumPendingEntries {
            guard let index = entries.firstIndex(where: {
                $0.outputBytes > 0 || $0.diagnosticBytes > 0
            }) else {
                return false
            }
            let kind: AgentRunEventDeliveryNoticeKind = entries[index].outputBytes > 0
                ? .outputTruncated
                : .diagnosticTruncated
            discardWholeEntry(at: index, noticeKind: kind)
        }
        return true
    }

    private func trimPayload(
        current: () -> Int,
        maximum: Int,
        category: AgentRunEventDeliveryNoticeKind)
    {
        while current() > maximum {
            let excess = current() - maximum
            guard let index = entries.firstIndex(where: { entry in
                switch category {
                case .outputTruncated:
                    entry.outputBytes > 0
                case .diagnosticTruncated:
                    entry.diagnosticBytes > 0
                case .controlTruncated:
                    false
                }
            }) else {
                return
            }
            let byteCount = category == .outputTruncated
                ? entries[index].outputBytes
                : entries[index].diagnosticBytes
            if byteCount <= excess {
                discardWholeEntry(at: index, noticeKind: category)
            } else {
                var entry = entries[index]
                let discarded = entry.discardTextPrefix(atLeast: excess)
                subtractCounters(for: entries[index])
                entries[index] = entry
                addCounters(for: entry)
                addDiscarded(kind: category, bytes: discarded, entries: 0)
                insertNotice(
                    at: index,
                    kind: category,
                    discardedBytes: UInt64(discarded),
                    discardedEntries: 0)
            }
        }
    }

    private func discardWholeEntry(
        at index: Int,
        noticeKind: AgentRunEventDeliveryNoticeKind)
    {
        let removed = remove(at: index)
        let bytes = noticeKind == .outputTruncated
            ? removed.outputBytes
            : removed.diagnosticBytes
        addDiscarded(kind: noticeKind, bytes: bytes, entries: 1)
        insertNotice(
            at: index,
            kind: noticeKind,
            discardedBytes: UInt64(bytes),
            discardedEntries: 1)
    }

    private func insertNotice(
        at index: Int,
        kind: AgentRunEventDeliveryNoticeKind,
        discardedBytes: UInt64,
        discardedEntries: UInt64)
    {
        if index > 0, entries[index - 1].noticeKind == kind {
            var notice = entries[index - 1]
            notice.addNoticeCounts(bytes: discardedBytes, entries: discardedEntries)
            entries[index - 1] = notice
            return
        }
        if index < entries.count, entries[index].noticeKind == kind {
            var notice = entries[index]
            notice.addNoticeCounts(bytes: discardedBytes, entries: discardedEntries)
            entries[index] = notice
            return
        }
        entries.insert(
            AgentRunEventDeliveryEntry(notice: AgentRunEventDeliveryNotice(
                kind: kind,
                discardedBytes: discardedBytes,
                discardedEntries: discardedEntries)),
            at: index)
    }

    private func addDiscarded(
        kind: AgentRunEventDeliveryNoticeKind,
        bytes: Int,
        entries: UInt64)
    {
        switch kind {
        case .outputTruncated:
            discardedOutputBytes = saturatingAdd(discardedOutputBytes, UInt64(bytes))
            discardedOutputEntries = saturatingAdd(discardedOutputEntries, entries)
        case .diagnosticTruncated:
            discardedDiagnosticBytes = saturatingAdd(discardedDiagnosticBytes, UInt64(bytes))
        case .controlTruncated:
            break
        }
    }

    private func popFirst() -> AgentRunEventDeliveryEntry? {
        guard let entry = entries.popFirst() else {
            return nil
        }
        subtractCounters(for: entry)
        return entry
    }

    private func remove(at index: Int) -> AgentRunEventDeliveryEntry {
        let entry = entries.remove(at: index)
        subtractCounters(for: entry)
        return entry
    }

    private func addCounters(for entry: AgentRunEventDeliveryEntry) {
        pendingOutputBytes += entry.outputBytes
        pendingDiagnosticBytes += entry.diagnosticBytes
        pendingControlBytes += entry.controlBytes
    }

    private func subtractCounters(for entry: AgentRunEventDeliveryEntry) {
        pendingOutputBytes -= entry.outputBytes
        pendingDiagnosticBytes -= entry.diagnosticBytes
        pendingControlBytes -= entry.controlBytes
    }
}

private struct AgentRunEventDeque {
    private var storage: [AgentRunEventDeliveryEntry] = []
    private var head = 0

    var count: Int {
        storage.count - head
    }

    var isEmpty: Bool {
        count == 0
    }

    subscript(index: Int) -> AgentRunEventDeliveryEntry {
        get {
            precondition(index >= 0 && index < count)
            return storage[head + index]
        }
        set {
            precondition(index >= 0 && index < count)
            storage[head + index] = newValue
        }
    }

    mutating func append(_ entry: AgentRunEventDeliveryEntry) {
        storage.append(entry)
    }

    func lastCanCoalesce(with entry: AgentRunEventDeliveryEntry) -> Bool {
        guard !isEmpty else {
            return false
        }
        return storage[storage.count - 1].canCoalesce(with: entry)
    }

    mutating func coalesceLast(
        with entry: AgentRunEventDeliveryEntry) -> AgentRunEventCoalescingChange
    {
        precondition(!isEmpty)
        let index = storage.count - 1
        let oldOutputBytes = storage[index].outputBytes
        let oldDiagnosticBytes = storage[index].diagnosticBytes
        let discarded = storage[index].appendText(from: entry)
        let noticeKind: AgentRunEventDeliveryNoticeKind = storage[index].outputBytes > 0
            ? .outputTruncated
            : .diagnosticTruncated
        return AgentRunEventCoalescingChange(
            outputByteDelta: storage[index].outputBytes - oldOutputBytes,
            diagnosticByteDelta: storage[index].diagnosticBytes - oldDiagnosticBytes,
            discardedBytes: discarded,
            noticeKind: noticeKind)
    }

    mutating func insert(_ entry: AgentRunEventDeliveryEntry, at index: Int) {
        precondition(index >= 0 && index <= count)
        storage.insert(entry, at: head + index)
    }

    mutating func popFirst() -> AgentRunEventDeliveryEntry? {
        guard !isEmpty else {
            return nil
        }
        let entry = storage[head]
        head += 1
        compactIfNeeded()
        return entry
    }

    mutating func remove(at index: Int) -> AgentRunEventDeliveryEntry {
        precondition(index >= 0 && index < count)
        let entry = storage.remove(at: head + index)
        compactIfNeeded()
        return entry
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    func firstIndex(where predicate: (AgentRunEventDeliveryEntry) -> Bool) -> Int? {
        for index in 0..<count where predicate(self[index]) {
            return index
        }
        return nil
    }

    private mutating func compactIfNeeded() {
        guard head >= 128 || head * 2 >= storage.count else {
            return
        }
        storage.removeSubrange(0..<head)
        head = 0
    }
}

private struct AgentRunEventCoalescingChange {
    let outputByteDelta: Int
    let diagnosticByteDelta: Int
    let discardedBytes: Int
    let noticeKind: AgentRunEventDeliveryNoticeKind
}

private struct AgentRunEventNormalization {
    let entries: [AgentRunEventDeliveryEntry]
}

private enum AgentRunEventNormalizationError: Error {
    case oversizedOpaqueIdentifier
    case oversizedPermission
}

private enum AgentRunEventNormalizer {
    private static let maximumControlTextBytes = 64 * 1_024
    private static let maximumPlanEntryBytes = 8 * 1_024

    static func normalize(_ event: AgentRunEvent) throws -> AgentRunEventNormalization {
        switch event {
        case let .agentMessageDelta(messageID, text):
            try validate(identifier: messageID)
            return textEntries(kind: .agentMessage(messageID), text: text)
        case let .thoughtDelta(messageID, text):
            try validate(identifier: messageID)
            return textEntries(kind: .thought(messageID), text: text)
        case let .diagnostic(text):
            return textEntries(kind: .diagnostic, text: text)
        case let .connected(agentName, sessionID):
            try validate(identifier: sessionID)
            let bounded = boundedPrefix(agentName, maximumBytes: maximumControlTextBytes)
            return controlEntries(
                event: .connected(agentName: bounded.value, sessionID: sessionID),
                discardedBytes: bounded.discardedBytes,
                discardedEntries: 0)
        case let .toolCall(toolCall):
            try validate(identifier: toolCall.id)
            let bounded = boundedPrefix(toolCall.title, maximumBytes: maximumControlTextBytes)
            return controlEntries(
                event: .toolCall(AgentToolCall(
                    id: toolCall.id,
                    title: bounded.value,
                    kind: toolCall.kind,
                    status: toolCall.status)),
                discardedBytes: bounded.discardedBytes,
                discardedEntries: 0)
        case let .toolCallUpdate(update):
            try validate(identifier: update.id)
            let bounded = update.title.map {
                boundedPrefix($0, maximumBytes: maximumControlTextBytes)
            }
            return controlEntries(
                event: .toolCallUpdate(AgentToolCallUpdate(
                    id: update.id,
                    title: bounded?.value,
                    kind: update.kind,
                    status: update.status)),
                discardedBytes: bounded?.discardedBytes ?? 0,
                discardedEntries: 0)
        case let .plan(plan):
            var discardedBytes = 0
            var discardedEntries = 0
            var retained: [AgentPlanEntry] = []
            retained.reserveCapacity(min(plan.count, AgentRunEventDelivery.maximumPlanEntries))
            for entry in plan.prefix(AgentRunEventDelivery.maximumPlanEntries) {
                let bounded = boundedPrefix(
                    entry.content,
                    maximumBytes: maximumPlanEntryBytes)
                discardedBytes = saturatingAdd(discardedBytes, bounded.discardedBytes)
                retained.append(AgentPlanEntry(
                    content: bounded.value,
                    priority: entry.priority,
                    status: entry.status))
            }
            if plan.count > retained.count {
                discardedEntries = plan.count - retained.count
                for entry in plan.dropFirst(retained.count) {
                    discardedBytes = saturatingAdd(discardedBytes, entry.content.utf8.count)
                }
            }
            return controlEntries(
                event: .plan(retained),
                discardedBytes: discardedBytes,
                discardedEntries: discardedEntries)
        case let .metadata(kind, summary):
            let boundedKind = boundedPrefix(kind, maximumBytes: maximumControlTextBytes)
            let boundedSummary = boundedPrefix(summary, maximumBytes: maximumControlTextBytes)
            return controlEntries(
                event: .metadata(kind: boundedKind.value, summary: boundedSummary.value),
                discardedBytes: saturatingAdd(
                    boundedKind.discardedBytes,
                    boundedSummary.discardedBytes),
                discardedEntries: 0)
        case let .unknown(discriminator, summary):
            let boundedDiscriminator = boundedPrefix(
                discriminator,
                maximumBytes: maximumControlTextBytes)
            let boundedSummary = boundedPrefix(summary, maximumBytes: maximumControlTextBytes)
            return controlEntries(
                event: .unknown(
                    discriminator: boundedDiscriminator.value,
                    summary: boundedSummary.value),
                discardedBytes: saturatingAdd(
                    boundedDiscriminator.discardedBytes,
                    boundedSummary.discardedBytes),
                discardedEntries: 0)
        case let .permissionRequested(request):
            try validate(request: request)
            let boundedTitle = request.toolCall.title.map {
                boundedPrefix($0, maximumBytes: maximumControlTextBytes)
            }
            let normalized = AgentPermissionRequest(
                turnToken: request.turnToken,
                requestID: request.requestID,
                toolCall: AgentToolCallUpdate(
                    id: request.toolCall.id,
                    title: boundedTitle?.value,
                    kind: request.toolCall.kind,
                    status: request.toolCall.status),
                options: request.options)
            guard AgentRunEventDeliveryEntry.controlByteCount(for: .permissionRequested(normalized))
                    <= AgentRunEventDelivery.maximumPendingControlBytes
            else {
                throw AgentRunEventNormalizationError.oversizedPermission
            }
            return controlEntries(
                event: .permissionRequested(normalized),
                discardedBytes: boundedTitle?.discardedBytes ?? 0,
                discardedEntries: 0)
        case .deliveryNotice:
            return AgentRunEventNormalization(entries: [AgentRunEventDeliveryEntry(event: event)])
        }
    }

    private static func textEntries(
        kind: AgentRunEventDeliveryTextKind,
        text: String) -> AgentRunEventNormalization
    {
        guard !text.isEmpty else {
            return AgentRunEventNormalization(entries: [])
        }
        let maximumBytes = kind == .diagnostic
            ? AgentRunEventDelivery.maximumPendingDiagnosticBytes
            : AgentRunEventDelivery.maximumPendingOutputBytes
        let buffer = AgentRunEventDeliveryTextBuffer(text, maximumBytes: maximumBytes)
        var entries: [AgentRunEventDeliveryEntry] = []
        if buffer.discardedOnInitialization > 0 {
            entries.append(AgentRunEventDeliveryEntry(notice: AgentRunEventDeliveryNotice(
                kind: kind == .diagnostic ? .diagnosticTruncated : .outputTruncated,
                discardedBytes: UInt64(buffer.discardedOnInitialization),
                discardedEntries: 0)))
        }
        entries.append(AgentRunEventDeliveryEntry(textKind: kind, buffer: buffer))
        return AgentRunEventNormalization(entries: entries)
    }

    private static func controlEntries(
        event: AgentRunEvent,
        discardedBytes: Int,
        discardedEntries: Int) -> AgentRunEventNormalization
    {
        var entries: [AgentRunEventDeliveryEntry] = []
        if discardedBytes > 0 || discardedEntries > 0 {
            entries.append(AgentRunEventDeliveryEntry(notice: AgentRunEventDeliveryNotice(
                kind: .controlTruncated,
                discardedBytes: UInt64(discardedBytes),
                discardedEntries: UInt64(discardedEntries))))
        }
        entries.append(AgentRunEventDeliveryEntry(event: event))
        return AgentRunEventNormalization(entries: entries)
    }

    private static func validate(request: AgentPermissionRequest) throws {
        try validate(requestID: request.requestID)
        try validate(identifier: request.toolCall.id)
        guard request.options.count <= AgentRunEventDelivery.maximumPermissionOptions else {
            throw AgentRunEventNormalizationError.oversizedPermission
        }
        for option in request.options {
            try validate(identifier: option.id)
        }
    }

    private static func validate(requestID: ACPRequestID) throws {
        if case let .string(identifier) = requestID {
            try validate(identifier: identifier)
        }
    }

    private static func validate(identifier: String?) throws {
        guard let identifier else {
            return
        }
        guard identifier.utf8.count <= AgentRunEventDelivery.maximumOpaqueIdentifierBytes else {
            throw AgentRunEventNormalizationError.oversizedOpaqueIdentifier
        }
    }
}

private enum AgentRunEventDeliveryTextKind: Equatable {
    case agentMessage(String?)
    case thought(String?)
    case diagnostic
}

private struct AgentRunEventDeliveryEntry {
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

private struct AgentRunEventDeliveryTextBuffer {
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

private struct BoundedControlText {
    let value: String
    let discardedBytes: Int
}

private func boundedPrefix(_ value: String, maximumBytes: Int) -> BoundedControlText {
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

private func utf8SuffixStart(in data: Data, maximumBytes: Int) -> Int {
    var start = max(0, data.count - maximumBytes)
    while start < data.count, isUTF8Continuation(data[start]) {
        start += 1
    }
    return start
}

private func isUTF8Continuation(_ byte: UInt8) -> Bool {
    byte & 0xC0 == 0x80
}

private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : result
}

private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : result
}

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// A lock-protected, single-consumer queue with independent text and control bounds.
///
/// Output and diagnostics may be coalesced or summarized under pressure. Required
/// control events instead report overflow so callers can terminate an unsafe turn.
final class AgentRunEventDeliveryQueue: @unchecked Sendable {
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

/// A head-indexed deque that avoids repeated front-removal copies during streaming.
struct AgentRunEventDeque {
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

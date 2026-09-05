// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import VoiceActivationCore

extension AgentRunPresentation {
    func publishTokenUpdate(runID: UUID) {
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
        diagnosticsRecorder.record(
            category: .ui,
            event: "agent_presentation.publication_deferred",
            level: .debug,
            fields: ["run_id": runID.uuidString])
        guard trailingPublicationTask == nil else { return }
        let delay = now.duration(to: deadline)
        trailingPublicationGeneration &+= 1
        let generation = trailingPublicationGeneration
        trailingPublicationTask = MainRunLoopScheduler.shared.schedule(after: delay) {
            [weak self] in
            guard let self,
                self.trailingPublicationGeneration == generation,
                self.runID == runID
            else { return }
            self.trailingPublicationTask = nil
            guard self.publicationIsPending else { return }
            self.publishNow()
        }
    }

    func flushPendingPublication() {
        guard publicationIsPending else { return }
        trailingPublicationGeneration &+= 1
        trailingPublicationTask?.cancel()
        trailingPublicationTask = nil
        publishNow()
    }

    func publishNow() {
        publicationIsPending = false
        lastPublicationAt = clock.now
        if let snapshot {
            diagnosticsRecorder.record(
                category: .ui,
                event: "agent_presentation.snapshot_ready",
                level: .debug,
                fields: [
                    "run_id": snapshot.runID.uuidString,
                    "timeline_item_count": String(snapshot.timeline.count),
                    "output_character_count": String(snapshot.output.count),
                    "tool_count": String(snapshot.tools.count),
                    "permission_count": String(snapshot.permissions.count),
                    "task_priority": String(Task.currentPriority.rawValue),
                ])
            onPublication?(snapshot)
        }
    }

    func startElapsedTimer(runID: UUID) {
        elapsedTaskGeneration &+= 1
        let generation = elapsedTaskGeneration
        let tickInterval = elapsedTickInterval
        elapsedTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: tickInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                MainRunLoopScheduler.shared.schedule { [weak self] in
                    guard let self,
                        self.elapsedTaskGeneration == generation,
                        self.runID == runID
                    else { return }
                    self.elapsedSeconds =
                        self.elapsedSeconds == Int.max
                        ? Int.max
                        : self.elapsedSeconds + 1
                    self.publishNow()
                }
            }
        }
    }

    func stopRuntimeTimers() {
        trailingPublicationGeneration &+= 1
        trailingPublicationTask?.cancel()
        trailingPublicationTask = nil
        publicationIsPending = false
        stopElapsedTimer()
    }

    /// Stops elapsed publications without disturbing an unrelated text publication.
    func stopElapsedTimer() {
        elapsedTaskGeneration &+= 1
        elapsedTask?.cancel()
        elapsedTask = nil
    }

    func cancelTimers() {
        stopRuntimeTimers()
        lastPublicationAt = nil
        startedAt = nil
    }

    func noticeDescription(_ notice: AgentRunEventDeliveryNotice) -> String {
        let subject =
            switch notice.kind {
            case .outputTruncated: "Earlier streamed output"
            case .diagnosticTruncated: "Earlier diagnostics"
            case .controlTruncated: "Oversized event details"
            }
        return "\(subject) omitted (\(notice.discardedBytes) bytes, "
            + "\(notice.discardedEntries) entries)."
    }
}

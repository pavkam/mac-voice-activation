import Foundation

public enum ACPAgentRunnerError: Error, Equatable, LocalizedError, Sendable {
    case cancelled
    case shutDown
    case turnAlreadyActive

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            "The agent run was cancelled."
        case .shutDown:
            "The agent runner has shut down."
        case .turnAlreadyActive:
            "Another agent prompt is already active."
        }
    }
}

public protocol ACPAgentRunnerClock: Sendable {
    func sleep(for duration: Duration) async
}

public struct ContinuousACPAgentRunnerClock: ACPAgentRunnerClock, Sendable {
    public init() {}

    public func sleep(for duration: Duration) async {
        try? await ContinuousClock().sleep(for: duration)
    }
}

public actor ACPAgentRunner: AgentHarnessRunning {
    public static let maximumStandardErrorBytes = 16 * 1_024

    private static let cancellationGracePeriod = Duration.seconds(2)
    private static let exitDrainGracePeriod = Duration.milliseconds(500)
    private static let promptSettlePeriod = Duration.milliseconds(25)

    private let transportFactory: any ACPTransportCreating
    private let clock: any ACPAgentRunnerClock
    private let drainClock: any ACPAgentRunnerClock
    private let settleClock: any ACPAgentRunnerClock
    private var records: [UUID: ACPAgentConnectionRecord] = [:]
    private var activeTurn: ACPAgentActiveTurn?
    private var isShutDown = false

    public init(
        transportFactory: any ACPTransportCreating = ACPProcessTransportFactory(),
        clock: any ACPAgentRunnerClock = ContinuousACPAgentRunnerClock(),
        drainClock: any ACPAgentRunnerClock = ContinuousACPAgentRunnerClock(),
        settleClock: any ACPAgentRunnerClock = ContinuousACPAgentRunnerClock())
    {
        self.transportFactory = transportFactory
        self.clock = clock
        self.drainClock = drainClock
        self.settleClock = settleClock
    }

    public func run(
        profileID: UUID,
        configuration: AgentHarnessConfiguration,
        prompt: String,
        onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws
        -> AgentRunResult
    {
        guard !isShutDown else {
            throw ACPAgentRunnerError.shutDown
        }
        guard activeTurn == nil else {
            throw ACPAgentRunnerError.turnAlreadyActive
        }

        let token = UUID()
        let completion = ACPAgentRunCompletionLatch()
        let delivery = ACPAgentRunnerEventDelivery(handler: onEvent)
        activeTurn = ACPAgentActiveTurn(
            token: token,
            profileID: profileID,
            recordID: nil,
            connection: nil,
            completion: completion,
            delivery: delivery,
            isCancelling: false)

        var runRecord: ACPAgentConnectionRecord?
        do {
            let record = try await connectionRecord(
                profileID: profileID,
                configuration: configuration,
                turnToken: token)
            runRecord = record
            guard ownsActiveTurn(token), !isActiveTurnCancelling(token) else {
                throw ACPAgentRunnerError.cancelled
            }
            guard let connection = record.connection else {
                throw ACPClientError.connectionClosed
            }
            updateActiveTurn(token: token, record: record, connection: connection)
            let recordID = record.id

            let result = try await connection.prompt(prompt) { [weak self] event in
                await self?.forward(
                    event: event,
                    turnToken: token,
                    profileID: profileID,
                    recordID: recordID)
            }
            if isActiveTurnCancelling(token), result.stopReason != .cancelled {
                throw ACPClientError.malformedResponse(
                    "A cancelled prompt returned a non-cancelled stopReason.")
            }

            if await processExitWasObservedDuringPromptSettlement(record: record) {
                _ = await record.exitTask?.result
            }

            await completion.resolve(.success(result))
            delivery.finish()
            _ = await delivery.task.result
            clearActiveTurn(token: token)
            return result
        } catch {
            await completion.resolve(.failure)
            if let runRecord, runRecord.exitStatus != nil {
                _ = await runRecord.exitTask?.result
            }
            delivery.finish()
            _ = await delivery.task.result
            if let runRecord {
                await discardRecord(
                    profileID: profileID,
                    recordID: runRecord.id,
                    fallbackRecord: runRecord)
            }
            clearActiveTurn(token: token)
            throw error
        }
    }

    public func resolvePermission(
        turnToken: AgentTurnToken,
        requestID: ACPRequestID,
        optionID: String?) async
    {
        guard let connection = activeTurn?.connection else {
            return
        }
        await connection.resolvePermission(
            turnToken: turnToken,
            requestID: requestID,
            optionID: optionID)
    }

    public func cancel() async {
        guard var turn = activeTurn, !turn.isCancelling else {
            return
        }
        turn.isCancelling = true
        activeTurn = turn

        let token = turn.token
        let profileID = turn.profileID
        let capturedRecordID = turn.recordID
        let completion = turn.completion
        if let connection = turn.connection {
            Task {
                await connection.cancel()
            }
        }

        var outcome = await raceCancellation(completion: completion)
        if case .deadline = outcome, let completed = await completion.completedValue() {
            outcome = .completion(completed)
        }

        if case let .completion(.success(result)) = outcome,
           result.stopReason == .cancelled
        {
            return
        }

        await forceEvictActiveRecord(
            turnToken: token,
            profileID: profileID,
            capturedRecordID: capturedRecordID)
    }

    public func reset(profileIDs: Set<UUID>) async {
        let removed = profileIDs.compactMap { profileID -> ACPAgentConnectionRecord? in
            guard let record = records.removeValue(forKey: profileID) else {
                return nil
            }
            if activeTurn?.recordID == record.id {
                activeTurn?.delivery.finish()
                activeTurn = nil
            }
            return record
        }

        for record in removed {
            await dispose(record)
        }
    }

    public func shutdown() async {
        guard !isShutDown else {
            return
        }
        isShutDown = true

        if let turn = activeTurn {
            turn.delivery.finish()
            if let connection = turn.connection {
                Task {
                    await connection.cancel()
                }
            }
        }
        activeTurn = nil

        let cachedRecords = Array(records.values)
        records.removeAll()
        for record in cachedRecords {
            await dispose(record)
        }
    }

    private func connectionRecord(
        profileID: UUID,
        configuration: AgentHarnessConfiguration,
        turnToken: UUID) async throws -> ACPAgentConnectionRecord
    {
        if let cached = records[profileID],
           cached.configuration == configuration,
           cached.connection != nil,
           cached.exitStatus == nil
        {
            updateActiveTurnRecord(token: turnToken, record: cached)
            return cached
        }

        if let replaced = records.removeValue(forKey: profileID) {
            await dispose(replaced)
            try ensureActiveTurn(token: turnToken)
        }

        let transport = try await transportFactory.makeTransport(configuration: configuration)
        guard ownsActiveTurn(turnToken) else {
            await transport.terminate()
            throw ACPAgentRunnerError.cancelled
        }

        let record = ACPAgentConnectionRecord(
            id: UUID(),
            profileID: profileID,
            configuration: configuration,
            transport: transport)
        records[profileID] = record
        updateActiveTurnRecord(token: turnToken, record: record)
        await startObservers(for: record)

        do {
            let connection = try await ACPClientConnection.connect(
                transport: transport,
                configuration: configuration)
            guard records[profileID]?.id == record.id,
                  ownsActiveTurn(turnToken),
                  !isActiveTurnCancelling(turnToken)
            else {
                await transport.terminate()
                await connection.close()
                throw ACPAgentRunnerError.cancelled
            }
            record.connection = connection
            updateActiveTurn(token: turnToken, record: record, connection: connection)
            return record
        } catch {
            if records[profileID]?.id == record.id {
                records.removeValue(forKey: profileID)
            }
            await dispose(record)
            throw error
        }
    }

    private func startObservers(for record: ACPAgentConnectionRecord) async {
        let diagnostics = await record.transport.diagnostics()
        let transport = record.transport
        let profileID = record.profileID
        let recordID = record.id
        record.diagnosticsTask = Task { [weak self] in
            for await data in diagnostics {
                if Task.isCancelled {
                    return
                }
                await self?.receivedDiagnostic(
                    data,
                    profileID: profileID,
                    recordID: recordID)
            }
            await self?.finishedDiagnostics(
                profileID: profileID,
                recordID: recordID)
        }
        let diagnosticsTask = record.diagnosticsTask
        record.exitTask = Task { [weak self] in
            let status = await transport.waitForExit()
            guard await self?.markProcessExited(
                status: status,
                profileID: profileID,
                recordID: recordID) == true
            else {
                return
            }

            let drainResult = await self?.raceDrain(transport: transport) ?? .deadline
            if case .deadline = drainResult {
                await transport.closeReadStreams()
            }
            await transport.waitForDrain()
            _ = await diagnosticsTask?.result
            await self?.processDrained(
                profileID: profileID,
                recordID: recordID)
        }
    }

    private func receivedDiagnostic(_ data: Data, profileID: UUID, recordID: UUID) {
        guard let record = records[profileID], record.id == recordID else {
            return
        }
        record.standardError.append(data)
        if record.standardError.count > Self.maximumStandardErrorBytes {
            record.standardError.removeFirst(
                record.standardError.count - Self.maximumStandardErrorBytes)
        }

        let decoded = decodeAvailableUTF8(
            appending: data,
            remainder: &record.diagnosticRemainder)

        guard !decoded.isEmpty,
              let turn = activeTurn,
              turn.profileID == profileID,
              turn.recordID == recordID
        else {
            return
        }
        turn.delivery.send(.diagnostic(decoded))
    }

    private func finishedDiagnostics(profileID: UUID, recordID: UUID) {
        guard let record = records[profileID], record.id == recordID else {
            return
        }
        guard !record.diagnosticRemainder.isEmpty else {
            return
        }
        let decoded = String(decoding: record.diagnosticRemainder, as: UTF8.self)
        record.diagnosticRemainder.removeAll(keepingCapacity: true)
        guard let turn = activeTurn,
              turn.profileID == profileID,
              turn.recordID == recordID
        else {
            return
        }
        turn.delivery.send(.diagnostic(decoded))
    }

    private func markProcessExited(status: Int32, profileID: UUID, recordID: UUID) async -> Bool {
        guard let record = records[profileID], record.id == recordID else {
            return false
        }
        record.exitStatus = status
        await record.exitObservation.resolve()

        return true
    }

    private func processDrained(profileID: UUID, recordID: UUID) async {
        guard let record = records[profileID], record.id == recordID else {
            return
        }
        if let connection = record.connection {
            await connection.waitForInputCompletion()
        }

        guard records[profileID]?.id == recordID else {
            return
        }
        if let status = record.exitStatus,
           status != 0,
           let turn = activeTurn,
           turn.profileID == profileID,
           turn.recordID == recordID
        {
            turn.delivery.send(.diagnostic("Agent process exited with status \(status)."))
        }
        records.removeValue(forKey: profileID)
    }

    private func raceDrain(transport: any ACPTransport) async -> ACPAgentDrainRace {
        await withTaskGroup(of: ACPAgentDrainRace.self) { group in
            group.addTask {
                await transport.waitForDrain()
                return .drained
            }
            group.addTask { [drainClock] in
                await drainClock.sleep(for: Self.exitDrainGracePeriod)
                return .deadline
            }
            let result = await group.next() ?? .deadline
            group.cancelAll()
            return result
        }
    }

    private func processExitWasObservedDuringPromptSettlement(
        record: ACPAgentConnectionRecord) async -> Bool
    {
        let exitObservation = record.exitObservation
        return await withTaskGroup(of: ACPAgentPromptSettleRace.self) { group in
            group.addTask {
                await exitObservation.wait()
                return .processExited
            }
            group.addTask { [settleClock] in
                await settleClock.sleep(for: Self.promptSettlePeriod)
                return .settled
            }
            let result = await group.next() ?? .settled
            group.cancelAll()
            if case .processExited = result {
                return true
            }
            return false
        }
    }

    func retainedStandardErrorByteCountForTesting(profileID: UUID) -> Int {
        records[profileID]?.standardError.count ?? 0
    }

    func pendingDiagnosticByteCountForTesting() -> Int {
        activeTurn?.delivery.pendingDiagnosticByteCount ?? 0
    }

    private func forward(
        event: AgentRunEvent,
        turnToken: UUID,
        profileID: UUID,
        recordID: UUID)
    {
        guard let turn = activeTurn,
              turn.token == turnToken,
              turn.profileID == profileID,
              turn.recordID == recordID,
              records[profileID]?.id == recordID
        else {
            return
        }
        turn.delivery.send(event)
    }

    private func raceCancellation(
        completion: ACPAgentRunCompletionLatch) async -> ACPAgentCancellationRace
    {
        await withTaskGroup(of: ACPAgentCancellationRace.self) { group in
            group.addTask {
                .completion(await completion.wait())
            }
            group.addTask { [clock] in
                await clock.sleep(for: Self.cancellationGracePeriod)
                return .deadline
            }
            let result = await group.next() ?? .deadline
            group.cancelAll()
            return result
        }
    }

    private func forceEvictActiveRecord(
        turnToken: UUID,
        profileID: UUID,
        capturedRecordID: UUID?) async
    {
        guard let turn = activeTurn, turn.token == turnToken else {
            return
        }
        let recordID = capturedRecordID ?? turn.recordID
        guard let recordID,
              let record = records[profileID],
              record.id == recordID
        else {
            turn.delivery.finish()
            activeTurn = nil
            return
        }

        records.removeValue(forKey: profileID)
        turn.delivery.finish()
        activeTurn = nil
        await record.transport.terminate()
        await record.transport.closeReadStreams()
        record.diagnosticsTask?.cancel()
        record.exitTask?.cancel()
        if let connection = record.connection {
            Task {
                await connection.close()
            }
        }
    }

    private func discardRecord(
        profileID: UUID,
        recordID: UUID,
        fallbackRecord: ACPAgentConnectionRecord) async
    {
        if records[profileID]?.id == recordID {
            records.removeValue(forKey: profileID)
            await dispose(fallbackRecord)
        } else {
            await fallbackRecord.transport.terminate()
        }
    }

    private func dispose(_ record: ACPAgentConnectionRecord) async {
        await record.transport.terminate()
        await record.transport.closeReadStreams()
        _ = await record.transport.waitForExit()
        await record.transport.waitForDrain()
        _ = await record.diagnosticsTask?.result
        _ = await record.exitTask?.result
        if let connection = record.connection {
            await connection.close()
        }
    }

    private func updateActiveTurnRecord(
        token: UUID,
        record: ACPAgentConnectionRecord)
    {
        guard var turn = activeTurn, turn.token == token else {
            return
        }
        turn.recordID = record.id
        activeTurn = turn
    }

    private func updateActiveTurn(
        token: UUID,
        record: ACPAgentConnectionRecord,
        connection: ACPClientConnection)
    {
        guard var turn = activeTurn, turn.token == token else {
            return
        }
        turn.recordID = record.id
        turn.connection = connection
        activeTurn = turn
    }

    private func ownsActiveTurn(_ token: UUID) -> Bool {
        activeTurn?.token == token
    }

    private func isActiveTurnCancelling(_ token: UUID) -> Bool {
        guard let turn = activeTurn, turn.token == token else {
            return true
        }
        return turn.isCancelling
    }

    private func ensureActiveTurn(token: UUID) throws {
        guard ownsActiveTurn(token), !isActiveTurnCancelling(token) else {
            throw ACPAgentRunnerError.cancelled
        }
    }

    private func clearActiveTurn(token: UUID) {
        if activeTurn?.token == token {
            activeTurn = nil
        }
    }
}

private final class ACPAgentConnectionRecord {
    let id: UUID
    let profileID: UUID
    let configuration: AgentHarnessConfiguration
    let transport: any ACPTransport
    var connection: ACPClientConnection?
    var diagnosticsTask: Task<Void, Never>?
    var exitTask: Task<Void, Never>?
    var standardError = Data()
    var diagnosticRemainder = Data()
    var exitStatus: Int32?
    let exitObservation = ACPAgentProcessExitLatch()

    init(
        id: UUID,
        profileID: UUID,
        configuration: AgentHarnessConfiguration,
        transport: any ACPTransport)
    {
        self.id = id
        self.profileID = profileID
        self.configuration = configuration
        self.transport = transport
    }
}

private struct ACPAgentActiveTurn {
    let token: UUID
    let profileID: UUID
    var recordID: UUID?
    var connection: ACPClientConnection?
    let completion: ACPAgentRunCompletionLatch
    let delivery: ACPAgentRunnerEventDelivery
    var isCancelling: Bool
}

private enum ACPAgentRunCompletion: Sendable {
    case success(AgentRunResult)
    case failure
}

private enum ACPAgentCancellationRace: Sendable {
    case completion(ACPAgentRunCompletion)
    case deadline
}

private enum ACPAgentDrainRace: Sendable {
    case drained
    case deadline
}

private enum ACPAgentPromptSettleRace: Sendable {
    case processExited
    case settled
}

private actor ACPAgentProcessExitLatch {
    private var wasResolved = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func resolve() {
        guard !wasResolved else {
            return
        }
        wasResolved = true
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if wasResolved || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

private actor ACPAgentRunCompletionLatch {
    private var value: ACPAgentRunCompletion?
    private var waiters: [UUID: CheckedContinuation<ACPAgentRunCompletion, Never>] = [:]

    func resolve(_ result: ACPAgentRunCompletion) {
        guard value == nil else {
            return
        }
        value = result
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: result)
        }
    }

    func wait() async -> ACPAgentRunCompletion {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let value {
                    continuation.resume(returning: value)
                } else if Task.isCancelled {
                    continuation.resume(returning: .failure)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func completedValue() -> ACPAgentRunCompletion? {
        value
    }

    private func cancelWaiter(id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: .failure)
    }
}

private struct ACPAgentRunnerEventDelivery: Sendable {
    let task: Task<Void, Never>
    private let state: ACPAgentRunnerEventDeliveryState

    var pendingDiagnosticByteCount: Int {
        state.pendingDiagnosticByteCount
    }

    init(handler: @escaping @Sendable (AgentRunEvent) async -> Void) {
        let state = ACPAgentRunnerEventDeliveryState()
        self.state = state
        task = Task {
            while let event = await state.next() {
                await handler(event)
            }
        }
    }

    func send(_ event: AgentRunEvent) {
        state.send(event)
    }

    func finish() {
        state.finish()
    }
}

private final class ACPAgentRunnerEventDeliveryState: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentRunEvent] = []
    private var waiter: CheckedContinuation<AgentRunEvent?, Never>?
    private var isFinished = false
    private var diagnosticBytes = 0

    var pendingDiagnosticByteCount: Int {
        lock.withLock { diagnosticBytes }
    }

    func send(_ event: AgentRunEvent) {
        let boundedEvent: AgentRunEvent
        if case let .diagnostic(message) = event {
            boundedEvent = .diagnostic(boundedSuffix(
                message,
                maximumBytes: ACPAgentRunner.maximumStandardErrorBytes))
        } else {
            boundedEvent = event
        }
        var waiting: CheckedContinuation<AgentRunEvent?, Never>?
        lock.withLock {
            guard !isFinished else {
                return
            }
            if let waiter {
                self.waiter = nil
                waiting = waiter
                return
            }
            enqueue(boundedEvent)
        }
        waiting?.resume(returning: boundedEvent)
    }

    func finish() {
        var waiting: CheckedContinuation<AgentRunEvent?, Never>?
        lock.withLock {
            guard !isFinished else {
                return
            }
            isFinished = true
            if events.isEmpty {
                waiting = waiter
                waiter = nil
            }
        }
        waiting?.resume(returning: nil)
    }

    func next() async -> AgentRunEvent? {
        await withCheckedContinuation { continuation in
            var immediateEvent: AgentRunEvent?
            var shouldFinish = false
            lock.withLock {
                if !events.isEmpty {
                    immediateEvent = events.removeFirst()
                    if case let .diagnostic(message) = immediateEvent {
                        diagnosticBytes -= message.utf8.count
                    }
                } else if isFinished {
                    shouldFinish = true
                } else {
                    waiter = continuation
                }
            }
            if let immediateEvent {
                continuation.resume(returning: immediateEvent)
            } else if shouldFinish {
                continuation.resume(returning: nil)
            }
        }
    }

    private func enqueue(_ event: AgentRunEvent) {
        guard case let .diagnostic(message) = event else {
            events.append(event)
            return
        }

        if case let .diagnostic(previous)? = events.last {
            let replacement = boundedSuffix(
                previous + message,
                maximumBytes: ACPAgentRunner.maximumStandardErrorBytes)
            diagnosticBytes -= previous.utf8.count
            diagnosticBytes += replacement.utf8.count
            events[events.count - 1] = .diagnostic(replacement)
        } else {
            let bounded = boundedSuffix(
                message,
                maximumBytes: ACPAgentRunner.maximumStandardErrorBytes)
            diagnosticBytes += bounded.utf8.count
            events.append(.diagnostic(bounded))
        }
        trimOldestDiagnosticsToBound()
    }

    private func trimOldestDiagnosticsToBound() {
        while diagnosticBytes > ACPAgentRunner.maximumStandardErrorBytes {
            guard let index = events.firstIndex(where: {
                if case .diagnostic = $0 {
                    return true
                }
                return false
            }), case let .diagnostic(message) = events[index]
            else {
                diagnosticBytes = 0
                return
            }

            let excess = diagnosticBytes - ACPAgentRunner.maximumStandardErrorBytes
            if message.utf8.count <= excess {
                diagnosticBytes -= message.utf8.count
                events.remove(at: index)
            } else {
                let replacement = boundedSuffix(
                    message,
                    maximumBytes: message.utf8.count - excess)
                diagnosticBytes -= message.utf8.count
                diagnosticBytes += replacement.utf8.count
                events[index] = .diagnostic(replacement)
            }
        }
    }
}

private func decodeAvailableUTF8(appending data: Data, remainder: inout Data) -> String {
    remainder.append(data)
    guard !remainder.isEmpty else {
        return ""
    }

    let incompleteCount = trailingIncompleteUTF8ByteCount(in: remainder)
    let readyCount = remainder.count - incompleteCount
    guard readyCount > 0 else {
        return ""
    }
    let ready = remainder.prefix(readyCount)
    if incompleteCount == 0 {
        remainder.removeAll(keepingCapacity: true)
    } else {
        remainder = Data(remainder.suffix(incompleteCount))
    }
    return String(decoding: ready, as: UTF8.self)
}

private func trailingIncompleteUTF8ByteCount(in data: Data) -> Int {
    let bytes = Array(data.suffix(4))
    guard !bytes.isEmpty else {
        return 0
    }

    var leadingIndex = bytes.count - 1
    while leadingIndex > 0, bytes[leadingIndex] & 0xC0 == 0x80 {
        leadingIndex -= 1
    }
    let leadingByte = bytes[leadingIndex]
    let expectedCount: Int
    switch leadingByte {
    case 0xC2...0xDF:
        expectedCount = 2
    case 0xE0...0xEF:
        expectedCount = 3
    case 0xF0...0xF4:
        expectedCount = 4
    default:
        return 0
    }
    let availableCount = bytes.count - leadingIndex
    return availableCount < expectedCount ? availableCount : 0
}

private func boundedSuffix(_ value: String, maximumBytes: Int) -> String {
    guard value.utf8.count > maximumBytes else {
        return value
    }

    var result = ""
    var bytes = 0
    for character in value.reversed() {
        let characterBytes = String(character).utf8.count
        guard bytes + characterBytes <= maximumBytes else {
            break
        }
        result.insert(character, at: result.startIndex)
        bytes += characterBytes
    }
    return result
}

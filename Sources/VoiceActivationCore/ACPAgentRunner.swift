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

    private let transportFactory: any ACPTransportCreating
    private let clock: any ACPAgentRunnerClock
    private var records: [UUID: ACPAgentConnectionRecord] = [:]
    private var activeTurn: ACPAgentActiveTurn?
    private var isShutDown = false

    public init(
        transportFactory: any ACPTransportCreating = ACPProcessTransportFactory(),
        clock: any ACPAgentRunnerClock = ContinuousACPAgentRunnerClock())
    {
        self.transportFactory = transportFactory
        self.clock = clock
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

            await completion.resolve(.success(result))
            delivery.finish()
            _ = await delivery.task.result
            clearActiveTurn(token: token)
            return result
        } catch {
            await completion.resolve(.failure)
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
        }
        record.exitTask = Task { [weak self] in
            let status = await transport.waitForExit()
            await self?.processExited(
                status: status,
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

        guard let turn = activeTurn,
              turn.profileID == profileID,
              turn.recordID == recordID
        else {
            return
        }
        let boundedData = data.suffix(Self.maximumStandardErrorBytes)
        let diagnostic = boundedSuffix(
            String(decoding: boundedData, as: UTF8.self),
            maximumBytes: Self.maximumStandardErrorBytes)
        if !diagnostic.isEmpty {
            turn.delivery.send(.diagnostic(diagnostic))
        }
    }

    private func processExited(status: Int32, profileID: UUID, recordID: UUID) {
        guard let record = records[profileID], record.id == recordID else {
            return
        }
        record.exitStatus = status
        records.removeValue(forKey: profileID)
        record.diagnosticsTask?.cancel()

        guard status != 0,
              let turn = activeTurn,
              turn.profileID == profileID,
              turn.recordID == recordID
        else {
            return
        }
        turn.delivery.send(.diagnostic("Agent process exited with status \(status)."))
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
        record.diagnosticsTask?.cancel()
        record.exitTask?.cancel()
        await record.transport.terminate()
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
        record.diagnosticsTask?.cancel()
        record.exitTask?.cancel()
        await record.transport.terminate()
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
    var exitStatus: Int32?

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
    private let continuation: AsyncStream<AgentRunEvent>.Continuation

    init(handler: @escaping @Sendable (AgentRunEvent) async -> Void) {
        let events = AsyncStream<AgentRunEvent>.makeStream()
        continuation = events.continuation
        task = Task {
            for await event in events.stream {
                await handler(event)
            }
        }
    }

    func send(_ event: AgentRunEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
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

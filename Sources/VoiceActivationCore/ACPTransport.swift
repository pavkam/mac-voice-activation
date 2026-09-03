import Foundation

public protocol ACPTransport: Sendable {
    func output() async -> AsyncThrowingStream<Data, any Error>
    func diagnostics() async -> AsyncStream<Data>
    func send(_ data: Data) async throws
    func waitForExit() async -> Int32
    func waitForDrain() async
    func closeReadStreams() async
    func terminate() async
}

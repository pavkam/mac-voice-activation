import Foundation

public struct AgentTurnToken: Equatable, Hashable, Sendable {
    private let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

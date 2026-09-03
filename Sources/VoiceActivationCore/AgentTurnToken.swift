public struct AgentTurnToken: Equatable, Hashable, Sendable {
    private let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

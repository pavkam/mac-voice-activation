import Foundation

public enum WakeProfileAction: Codable, Equatable, Sendable {
    case command(CommandTemplate)
    case agent(AgentHarnessConfiguration)
}

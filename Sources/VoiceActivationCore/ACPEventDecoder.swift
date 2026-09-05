// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// Converts validated ACP session-update notifications into bounded app events.
public struct ACPEventDecoder: Sendable {
    /// The maximum retained UTF-8 size for generated metadata summaries.
    public static let maximumSummaryBytes = 256
    /// The maximum retained UTF-8 size for opaque remote identifiers.
    public static let maximumOpaqueIdentifierBytes = AgentRunEventDelivery.maximumOpaqueIdentifierBytes

    /// Errors raised when a session update does not match its declared shape.
    public enum EventError: Error, Equatable, Sendable {
        /// A required field was missing, invalid, or outside its accepted bound.
        case malformedSessionUpdate(String)
    }

    private static let maximumDiscriminatorBytes = 128

    /// Creates a stateless ACP event decoder.
    public init() {}

    /// Decodes a `session/update` notification and ignores unrelated messages.
    ///
    /// - Parameter message: A validated JSON-RPC message.
    /// - Returns: A bounded app event, or `nil` for a non-session notification.
    /// - Throws: ``EventError`` when the declared session-update payload is malformed.
    public func event(from message: ACPMessage) throws -> AgentRunEvent? {
        guard case let .notification(method, params) = message, method == "session/update" else {
            return nil
        }

        let parameters = try object(params, named: "params")
        _ = try opaqueString(parameters["sessionId"], named: "sessionId")
        let update = try object(parameters["update"], named: "update")
        let discriminator = try string(update["sessionUpdate"], named: "sessionUpdate")

        switch discriminator {
        case "user_message_chunk":
            let chunk = try contentChunk(update)
            let suffix = chunk.messageID.map { " (\($0))" } ?? ""
            return .metadata(
                kind: discriminator,
                summary: bounded("User message chunk\(suffix)"))
        case "agent_message_chunk":
            let chunk = try contentChunk(update)
            guard let text = chunk.text else {
                return .metadata(
                    kind: discriminator,
                    summary: bounded("Agent sent \(chunk.contentType) content"))
            }
            return .agentMessageDelta(messageID: chunk.messageID, text: text)
        case "agent_thought_chunk":
            let chunk = try contentChunk(update)
            guard let text = chunk.text else {
                return .metadata(
                    kind: discriminator,
                    summary: bounded("Agent sent \(chunk.contentType) thought content"))
            }
            return .thoughtDelta(messageID: chunk.messageID, text: text)
        case "tool_call":
            return .toolCall(try toolCall(update))
        case "tool_call_update":
            return .toolCallUpdate(try toolCallUpdate(update))
        case "plan":
            return .plan(try plan(update))
        case "available_commands_update":
            return .metadata(kind: discriminator, summary: try availableCommandsSummary(update))
        case "current_mode_update":
            let mode = try string(update["currentModeId"], named: "currentModeId")
            return .metadata(kind: discriminator, summary: bounded("Current mode: \(mode)"))
        case "config_option_update":
            return .metadata(kind: discriminator, summary: try configOptionsSummary(update))
        case "session_info_update":
            return .metadata(kind: discriminator, summary: try sessionInfoSummary(update))
        case "usage_update":
            return .metadata(kind: discriminator, summary: try usageSummary(update))
        default:
            let retainedDiscriminator = bounded(
                discriminator,
                maximumBytes: Self.maximumDiscriminatorBytes)
            return .unknown(
                discriminator: retainedDiscriminator,
                summary: bounded("Unsupported ACP session update: \(retainedDiscriminator)"))
        }
    }

    private func contentChunk(_ update: [String: ACPJSONValue]) throws -> ContentChunk {
        let content = try object(update["content"], named: "content")
        let contentType = try string(content["type"], named: "content.type")
        let messageID = try optionalOpaqueString(update["messageId"], named: "messageId")

        switch contentType {
        case "text":
            return ContentChunk(
                contentType: contentType,
                messageID: messageID,
                text: try string(content["text"], named: "content.text"))
        case "image":
            _ = try string(content["data"], named: "content.data")
            _ = try string(content["mimeType"], named: "content.mimeType")
        case "audio":
            _ = try string(content["data"], named: "content.data")
            _ = try string(content["mimeType"], named: "content.mimeType")
        case "resource_link":
            _ = try string(content["name"], named: "content.name")
            _ = try string(content["uri"], named: "content.uri")
        case "resource":
            try validateEmbeddedResource(content)
        default:
            throw malformed("content.type")
        }

        return ContentChunk(contentType: contentType, messageID: messageID, text: nil)
    }

    private func validateEmbeddedResource(_ content: [String: ACPJSONValue]) throws {
        let resource = try object(content["resource"], named: "content.resource")
        _ = try string(resource["uri"], named: "content.resource.uri")

        if case .string = resource["text"] {
            return
        }
        if case .string = resource["blob"] {
            return
        }

        throw malformed("content.resource.text or content.resource.blob")
    }

    private func toolCall(_ update: [String: ACPJSONValue]) throws -> AgentToolCall {
        AgentToolCall(
            id: try opaqueString(update["toolCallId"], named: "toolCallId"),
            title: try string(update["title"], named: "title"),
            kind: try optionalRawValue(update["kind"], named: "kind"),
            status: try optionalRawValue(update["status"], named: "status"))
    }

    private func toolCallUpdate(_ update: [String: ACPJSONValue]) throws -> AgentToolCallUpdate {
        AgentToolCallUpdate(
            id: try opaqueString(update["toolCallId"], named: "toolCallId"),
            title: try optionalString(update["title"], named: "title"),
            kind: try optionalRawValue(update["kind"], named: "kind"),
            status: try optionalRawValue(update["status"], named: "status"))
    }

    private func plan(_ update: [String: ACPJSONValue]) throws -> [AgentPlanEntry] {
        try array(update["entries"], named: "entries").enumerated().map { index, value in
            let entry = try object(value, named: "entries[\(index)]")
            return AgentPlanEntry(
                content: try string(entry["content"], named: "entries[\(index)].content"),
                priority: try rawValue(
                    entry["priority"],
                    named: "entries[\(index)].priority"),
                status: try rawValue(
                    entry["status"],
                    named: "entries[\(index)].status"))
        }
    }

    private func availableCommandsSummary(_ update: [String: ACPJSONValue]) throws -> String {
        let commands = try array(update["availableCommands"], named: "availableCommands")
        let names = try commands.enumerated().map { index, value in
            let command = try object(value, named: "availableCommands[\(index)]")
            let name = try string(command["name"], named: "availableCommands[\(index)].name")
            _ = try string(
                command["description"],
                named: "availableCommands[\(index)].description")
            return name
        }
        let noun = names.count == 1 ? "command" : "commands"
        let listedNames = names.prefix(8).joined(separator: ", ")
        return bounded("\(names.count) \(noun) available: \(listedNames)")
    }

    private func configOptionsSummary(_ update: [String: ACPJSONValue]) throws -> String {
        let values = try array(update["configOptions"], named: "configOptions")
        let identifiers = try values.enumerated().map { index, value in
            let option = try object(value, named: "configOptions[\(index)]")
            let identifier = try string(option["id"], named: "configOptions[\(index)].id")
            _ = try string(option["name"], named: "configOptions[\(index)].name")
            let type = try string(option["type"], named: "configOptions[\(index)].type")

            switch type {
            case "select":
                _ = try string(
                    option["currentValue"],
                    named: "configOptions[\(index)].currentValue")
                let choices = try array(
                    option["options"],
                    named: "configOptions[\(index)].options")
                try validateConfigSelectOptions(choices, optionIndex: index)
            case "boolean":
                guard case .bool = option["currentValue"] else {
                    throw malformed("configOptions[\(index)].currentValue")
                }
            default:
                throw malformed("configOptions[\(index)].type")
            }

            return identifier
        }
        let noun = identifiers.count == 1 ? "option" : "options"
        let listedIdentifiers = identifiers.prefix(8).joined(separator: ", ")
        return bounded("\(identifiers.count) configuration \(noun) available: \(listedIdentifiers)")
    }

    private func validateConfigSelectOptions(
        _ choices: [ACPJSONValue],
        optionIndex: Int) throws
    {
        guard let firstChoice = choices.first else {
            return
        }
        let firstObject = try object(
            firstChoice,
            named: "configOptions[\(optionIndex)].options[0]")

        if firstObject.keys.contains("group") {
            for (groupIndex, groupValue) in choices.enumerated() {
                let group = try object(
                    groupValue,
                    named: "configOptions[\(optionIndex)].options[\(groupIndex)]")
                _ = try string(group["group"], named: "config option group")
                _ = try string(group["name"], named: "config option group name")
                let groupChoices = try array(
                    group["options"],
                    named: "config option group choices")
                try validateFlatConfigSelectOptions(groupChoices)
            }
        } else {
            try validateFlatConfigSelectOptions(choices)
        }
    }

    private func validateFlatConfigSelectOptions(_ choices: [ACPJSONValue]) throws {
        for choiceValue in choices {
            let choice = try object(choiceValue, named: "config option choice")
            _ = try string(choice["value"], named: "config option value")
            _ = try string(choice["name"], named: "config option name")
        }
    }

    private func sessionInfoSummary(_ update: [String: ACPJSONValue]) throws -> String {
        let title = try optionalString(update["title"], named: "title")
        let updatedAt = try optionalString(update["updatedAt"], named: "updatedAt")
        var parts: [String] = []

        if let title {
            parts.append("Session title: \(title)")
        } else if update.keys.contains("title") {
            parts.append("Session title cleared")
        }
        if let updatedAt {
            parts.append("updated: \(updatedAt)")
        } else if update.keys.contains("updatedAt") {
            parts.append("update time cleared")
        }

        return bounded(parts.isEmpty ? "Session information changed" : parts.joined(separator: "; "))
    }

    private func usageSummary(_ update: [String: ACPJSONValue]) throws -> String {
        let used = try unsignedInteger(update["used"], named: "used")
        let size = try unsignedInteger(update["size"], named: "size")
        var summary = "Context usage: \(used) of \(size) tokens"

        if let costValue = update["cost"], costValue != .null {
            let cost = try object(costValue, named: "cost")
            let amount = try number(cost["amount"], named: "cost.amount")
            let currency = try string(cost["currency"], named: "cost.currency")
            summary += "; cost: \(amount) \(currency)"
        }

        return bounded(summary)
    }

    private func object(
        _ value: ACPJSONValue?,
        named name: String) throws -> [String: ACPJSONValue]
    {
        guard case let .object(object) = value else {
            throw malformed(name)
        }
        return object
    }

    private func array(_ value: ACPJSONValue?, named name: String) throws -> [ACPJSONValue] {
        guard case let .array(array) = value else {
            throw malformed(name)
        }
        return array
    }

    private func string(_ value: ACPJSONValue?, named name: String) throws -> String {
        guard case let .string(string) = value else {
            throw malformed(name)
        }
        return string
    }

    private func optionalString(_ value: ACPJSONValue?, named name: String) throws -> String? {
        guard let value, value != .null else {
            return nil
        }
        return try string(value, named: name)
    }

    private func opaqueString(_ value: ACPJSONValue?, named name: String) throws -> String {
        let identifier = try string(value, named: name)
        guard identifier.utf8.count <= Self.maximumOpaqueIdentifierBytes else {
            throw malformed(name)
        }
        return identifier
    }

    private func optionalOpaqueString(
        _ value: ACPJSONValue?,
        named name: String) throws -> String?
    {
        guard let value, value != .null else {
            return nil
        }
        return try opaqueString(value, named: name)
    }

    private func rawValue<Value>(
        _ value: ACPJSONValue?,
        named name: String) throws -> Value
    where Value: RawRepresentable, Value.RawValue == String {
        let encoded = try string(value, named: name)
        guard let decoded = Value(rawValue: encoded) else {
            throw malformed(name)
        }
        return decoded
    }

    private func optionalRawValue<Value>(
        _ value: ACPJSONValue?,
        named name: String) throws -> Value?
    where Value: RawRepresentable, Value.RawValue == String {
        guard let value, value != .null else {
            return nil
        }
        return try rawValue(value, named: name)
    }

    private func unsignedInteger(_ value: ACPJSONValue?, named name: String) throws -> UInt64 {
        switch value {
        case let .integer(integer) where integer >= 0:
            return UInt64(integer)
        case let .unsignedInteger(integer):
            return integer
        default:
            throw malformed(name)
        }
    }

    private func number(_ value: ACPJSONValue?, named name: String) throws -> String {
        switch value {
        case let .integer(number):
            return String(number)
        case let .unsignedInteger(number):
            return String(number)
        case let .number(number):
            return String(number)
        default:
            throw malformed(name)
        }
    }

    private func malformed(_ field: String) -> EventError {
        .malformedSessionUpdate("Invalid or missing \(field).")
    }

    private func bounded(
        _ value: String,
        maximumBytes: Int = Self.maximumSummaryBytes) -> String
    {
        guard value.utf8.count > maximumBytes else {
            return value
        }

        var result = ""
        var byteCount = 0
        for character in value {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= maximumBytes else {
                break
            }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }
}

private struct ContentChunk: Sendable {
    let contentType: String
    let messageID: String?
    let text: String?
}

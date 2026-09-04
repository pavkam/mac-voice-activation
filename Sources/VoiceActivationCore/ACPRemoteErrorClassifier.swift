// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

enum ACPRemoteErrorClassifier {
    private static let maximumInspectedValues = 64
    private static let maximumInspectedBytes = 1_024
    private static let competingResourceWords: Set<String> = [
        "command", "directory", "file", "path", "project", "tool", "workspace",
    ]

    static func clientError(
        for error: ACPJSONRPCError,
        safeMessage: String,
        isPromptResponse: Bool,
        promptHadActivity: Bool) -> ACPClientError
    {
        guard isPromptResponse,
              !promptHadActivity,
              isCompatibleMissingResourceCode(error.code),
              indicatesUnavailableSession(message: safeMessage, data: error.data)
        else {
            return .remoteError(code: error.code, message: safeMessage)
        }

        return .sessionUnavailable(code: error.code, message: safeMessage)
    }

    private static func isCompatibleMissingResourceCode(_ code: Int64) -> Bool {
        code == -32_002 || code == -32_602 || code == -32_603
    }

    private static func indicatesUnavailableSession(
        message: String,
        data: ACPJSONValue?) -> Bool
    {
        if containsUnavailableSessionPhrase(message) {
            return true
        }
        guard let data else {
            return false
        }

        var collector = ACPRemoteErrorTextCollector(
            remainingValues: maximumInspectedValues,
            remainingBytes: maximumInspectedBytes)
        collector.collect(data)
        if containsUnavailableSessionPhrase(collector.text) {
            return true
        }
        return containsMissingResourcePhrase(message)
            && !mentionsCompetingResource(in: message)
            && identifiesSessionResource(collector.text)
    }

    private static func containsUnavailableSessionPhrase(_ text: String) -> Bool {
        let words = words(in: text)
        guard !words.isEmpty else {
            return false
        }

        for sessionIndex in words.indices where isSessionWord(words[sessionIndex]) {
            let lower = max(words.startIndex, sessionIndex - 5)
            let upper = min(words.endIndex, sessionIndex + 6)
            let nearby = Array(words[lower..<upper])
            let localSessionIndex = sessionIndex - lower
            guard !nearby.contains(where: competingResourceWords.contains) else {
                continue
            }
            if containsStateWord(
                in: nearby,
                sessionIndex: localSessionIndex,
                candidates: ["expired", "unknown", "invalid", "missing", "stale", "gone"])
            {
                return true
            }
            if containsRelatedWords(
                "not",
                "found",
                in: nearby,
                sessionIndex: localSessionIndex)
            {
                return true
            }
            if nearby.contains("exist"),
               nearby.contains(where: { $0 == "not" || $0 == "no" || $0 == "doesn" })
            {
                return true
            }
            if containsRelatedWords(
                "no",
                "such",
                in: nearby,
                sessionIndex: localSessionIndex)
                || containsRelatedWords(
                    "no",
                    "longer",
                    in: nearby,
                    sessionIndex: localSessionIndex)
                || containsRelatedWords(
                    "failed",
                    "find",
                    in: nearby,
                    sessionIndex: localSessionIndex)
            {
                return true
            }
        }

        return false
    }

    private static func containsMissingResourcePhrase(_ text: String) -> Bool {
        let words = words(in: text)
        guard !words.isEmpty else {
            return false
        }
        if words.contains("missing") || words.contains("unknown") {
            return true
        }
        return containsRelatedWords("not", "found", in: words)
            || containsRelatedWords("no", "such", in: words)
    }

    private static func identifiesSessionResource(_ text: String) -> Bool {
        let words = words(in: text)
        guard words.contains(where: isSessionWord) else {
            return false
        }
        return !words.contains(where: competingResourceWords.contains)
    }

    private static func mentionsCompetingResource(in text: String) -> Bool {
        words(in: text).contains(where: competingResourceWords.contains)
    }

    private static func words(in text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func isSessionWord(_ word: String) -> Bool {
        word == "session" || word == "sessionid"
    }

    private static func containsStateWord(
        in words: [String],
        sessionIndex: Int,
        candidates: Set<String>) -> Bool
    {
        words.indices.contains { index in
            abs(index - sessionIndex) <= 2 && candidates.contains(words[index])
        }
    }

    private static func containsRelatedWords(
        _ first: String,
        _ second: String,
        in words: [String],
        sessionIndex: Int) -> Bool
    {
        let firstIndices = words.indices.filter { words[$0] == first }
        let secondIndices = words.indices.filter { words[$0] == second }
        return firstIndices.contains { firstIndex in
            secondIndices.contains { secondIndex in
                abs(firstIndex - secondIndex) <= 3
                    && abs(firstIndex - sessionIndex) <= 5
                    && abs(secondIndex - sessionIndex) <= 5
            }
        }
    }

    private static func containsRelatedWords(
        _ first: String,
        _ second: String,
        in words: [String]) -> Bool
    {
        let firstIndices = words.indices.filter { words[$0] == first }
        let secondIndices = words.indices.filter { words[$0] == second }
        return firstIndices.contains { firstIndex in
            secondIndices.contains { secondIndex in
                abs(firstIndex - secondIndex) <= 3
            }
        }
    }
}

private struct ACPRemoteErrorTextCollector {
    var remainingValues: Int
    var remainingBytes: Int
    private(set) var text = ""

    mutating func collect(_ value: ACPJSONValue) {
        guard remainingValues > 0, remainingBytes > 0 else {
            return
        }
        remainingValues -= 1

        switch value {
        case let .string(string):
            append(string)
        case let .array(values):
            for value in values {
                collect(value)
                guard remainingValues > 0, remainingBytes > 0 else {
                    return
                }
            }
        case let .object(values):
            for key in values.keys.sorted() {
                append(key)
                if let value = values[key] {
                    collect(value)
                }
                guard remainingValues > 0, remainingBytes > 0 else {
                    return
                }
            }
        case .null, .bool, .integer, .unsignedInteger, .number:
            return
        }
    }

    private mutating func append(_ value: String) {
        guard remainingBytes > 0 else {
            return
        }
        if !text.isEmpty {
            text.append(" ")
            remainingBytes -= 1
        }
        guard remainingBytes > 0 else {
            return
        }

        for character in value {
            let byteCount = String(character).utf8.count
            guard byteCount <= remainingBytes else {
                return
            }
            text.append(character)
            remainingBytes -= byteCount
        }
    }
}

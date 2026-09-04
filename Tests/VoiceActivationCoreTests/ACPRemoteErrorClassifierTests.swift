// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Testing
@testable import VoiceActivationCore

@Suite
struct ACPRemoteErrorClassifierTests {
    @Test(arguments: [
        ACPJSONRPCError(code: -32_002, message: "Session not found"),
        ACPJSONRPCError(code: -32_603, message: "Unknown session id"),
        ACPJSONRPCError(code: -32_602, message: "No such session"),
        ACPJSONRPCError(code: -32_002, message: "Session doesn't exist"),
        ACPJSONRPCError(code: -32_002, message: "Session with id abc not found"),
        ACPJSONRPCError(code: -32_002, message: "The session has expired"),
        ACPJSONRPCError(
            code: -32_603,
            message: "Request failed",
            data: .object([
                "details": .object([
                    "session_id": .string("Session was not found"),
                ]),
            ])),
        ACPJSONRPCError(
            code: -32_002,
            message: "Resource not found",
            data: .object([
                "resourceType": .string("session"),
                "resourceId": .string("abc"),
            ])),
    ])
    func clientError_WhenSessionIsUnavailable_ClassifiesSafePromptFailure(
        remoteError: ACPJSONRPCError)
    {
        let result = ACPRemoteErrorClassifier.clientError(
            for: remoteError,
            safeMessage: remoteError.message,
            isPromptResponse: true,
            promptHadActivity: false)

        #expect(result == .sessionUnavailable(
            code: remoteError.code,
            message: remoteError.message))
    }

    @Test(arguments: [
        ACPJSONRPCError(code: -32_000, message: "Session not found"),
        ACPJSONRPCError(code: -32_002, message: "File not found"),
        ACPJSONRPCError(
            code: -32_002,
            message: "Session setup failed because file not found"),
        ACPJSONRPCError(
            code: -32_002,
            message: "Session failed because file not found"),
    ])
    func clientError_WhenFailureIsNotMissingSession_RemainsRemote(
        remoteError: ACPJSONRPCError)
    {
        let result = ACPRemoteErrorClassifier.clientError(
            for: remoteError,
            safeMessage: remoteError.message,
            isPromptResponse: true,
            promptHadActivity: false)

        #expect(result == .remoteError(
            code: remoteError.code,
            message: remoteError.message))
    }

    @Test func clientError_WhenPromptAlreadyProducedActivity_RemainsRemote() {
        let remoteError = ACPJSONRPCError(code: -32_002, message: "Session not found")

        let result = ACPRemoteErrorClassifier.clientError(
            for: remoteError,
            safeMessage: remoteError.message,
            isPromptResponse: true,
            promptHadActivity: true)

        #expect(result == .remoteError(
            code: remoteError.code,
            message: remoteError.message))
    }

    @Test func clientError_WhenAnotherRequestFails_RemainsRemote() {
        let remoteError = ACPJSONRPCError(code: -32_002, message: "Session not found")

        let result = ACPRemoteErrorClassifier.clientError(
            for: remoteError,
            safeMessage: remoteError.message,
            isPromptResponse: false,
            promptHadActivity: false)

        #expect(result == .remoteError(
            code: remoteError.code,
            message: remoteError.message))
    }
}

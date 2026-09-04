// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import Testing
@testable import VoiceActivationApp
@testable import VoiceActivationCore

@Suite(.serialized)
struct AgentRunElapsedTimeViewTests {
    @MainActor @Test func view_WhenAgentIsSilent_ElapsedTimeStillAdvances() async throws {
        let elapsedView = AgentRunElapsedTimeView(
            phase: .listening,
            elapsedSeconds: 0,
            startedAt: Date())
            .frame(width: 80, height: 24)
            .background(.black)
        let pixels = try await renderedPixelSnapshots(of: elapsedView)

        #expect(pixels.initial != pixels.updated)
    }

    @MainActor @Test func view_WhenAgentFinishes_ElapsedTimeStopsAdvancing() async throws {
        let elapsedView = AgentRunElapsedTimeView(
            phase: .completed(.endTurn),
            elapsedSeconds: 62,
            startedAt: Date())
            .frame(width: 80, height: 24)
            .background(.black)
        let pixels = try await renderedPixelSnapshots(of: elapsedView)

        #expect(pixels.initial == pixels.updated)
    }

    @MainActor
    private func renderedPixelSnapshots<Content: View>(
        of content: Content) async throws -> (initial: Data, updated: Data)
    {
        let size = NSSize(width: 80, height: 24)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.contentView = hostingView
        defer { window.contentView = nil }
        hostingView.layoutSubtreeIfNeeded()
        let initialPixels = try renderedPixels(of: hostingView)

        try await Task.sleep(for: .milliseconds(1_100))

        hostingView.layoutSubtreeIfNeeded()
        let updatedPixels = try renderedPixels(of: hostingView)
        return (initialPixels, updatedPixels)
    }

    @MainActor
    private func renderedPixels(of view: NSView) throws -> Data {
        let representation = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        return try #require(representation.tiffRepresentation)
    }
}

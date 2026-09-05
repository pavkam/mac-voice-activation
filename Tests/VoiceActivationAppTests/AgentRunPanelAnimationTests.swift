// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import MachO
import SwiftUI
import Testing

@testable import VoiceActivationApp
@testable import VoiceActivationCore

@MainActor
private struct AgentRunActionDockHarness: View {
    @Bindable var model: AgentRunPanelModel

    var body: some View {
        if let snapshot = model.snapshot {
            AgentRunPanelView(model: model).actionDock(snapshot)
        }
    }
}

struct AgentRunPanelAnimationTests {
    private static let childEnvironmentKey =
        "VOICE_ACTIVATION_ACTION_DOCK_ANIMATION_TEST_CHILD"
    private static let testFilter =
        "actionDock_WhenAgentFinishes_AnimatesOutgoingAndIncomingButtons"

    @MainActor @Test
    func actionDock_WhenAgentFinishes_AnimatesOutgoingAndIncomingButtons() async throws {
        guard ProcessInfo.processInfo.environment[Self.childEnvironmentKey] == "1" else {
            try runInIsolatedAppKitProcess()
            return
        }

        let model = AgentRunPanelModel()
        let running = runningSnapshot(runID: UUID())
        model.begin(running)
        let hostingView = NSHostingView(rootView: AgentRunActionDockHarness(model: model))
        hostingView.frame = NSRect(x: 0, y: 0, width: 620, height: 58)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.animationBehavior = .none
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        let initialRedPixels = try redPixelCount(inLeadingHalfOf: hostingView)
        #expect(initialRedPixels > 20)

        model.update(replacingPhase(.completed(.endTurn), in: running))
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        let transitioningRedPixels = try redPixelCount(inLeadingHalfOf: hostingView)
        try await Task.sleep(for: .milliseconds(400))
        let finalRedPixels = try redPixelCount(inLeadingHalfOf: hostingView)

        #expect(transitioningRedPixels > 0)
        #expect(finalRedPixels == 0)
    }

    @MainActor
    private func runInIsolatedAppKitProcess() throws {
        let testExecutable = try #require(CommandLine.arguments.first { argument in
            argument.contains(".xctest/Contents/MacOS/")
        })
        let helperExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
        let process = Process()
        let output = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment[Self.childEnvironmentKey] = "1"
        let sanitizerPaths = loadedSanitizerRuntimePaths()
        if !sanitizerPaths.isEmpty {
            var insertionPaths = environment["DYLD_INSERT_LIBRARIES"]
                .map { $0.split(separator: ":").map(String.init) } ?? []
            for path in sanitizerPaths where !insertionPaths.contains(path) {
                insertionPaths.append(path)
            }
            environment["DYLD_INSERT_LIBRARIES"] = insertionPaths.joined(separator: ":")
        }
        process.executableURL = helperExecutable
        process.arguments = [
            "--test-bundle-path", testExecutable,
            "--filter", Self.testFilter,
            testExecutable,
            "--testing-library", "swift-testing",
        ]
        process.environment = environment
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let details = String(decoding: data, as: UTF8.self)

        #expect(
            process.terminationReason == .exit && process.terminationStatus == 0,
            Comment(rawValue: details))
    }

    /// Returns sanitizer runtimes that a nested test process must load before its bundle.
    private func loadedSanitizerRuntimePaths() -> [String] {
        (0..<_dyld_image_count()).compactMap { index in
            guard let imageName = _dyld_get_image_name(index) else { return nil }
            let path = String(cString: imageName)
            guard path.contains("/libclang_rt."), path.hasSuffix("_dynamic.dylib") else {
                return nil
            }
            return path
        }
    }

    @MainActor
    private func redPixelCount(inLeadingHalfOf view: NSView) throws -> Int {
        let representation = try #require(
            view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        var count = 0
        for x in 0..<(representation.pixelsWide / 2) {
            for y in 0..<representation.pixelsHigh {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                if color.redComponent > 0.45,
                    color.redComponent > color.greenComponent * 1.35,
                    color.redComponent > color.blueComponent * 1.18,
                    color.alphaComponent > 0.25
                {
                    count += 1
                }
            }
        }
        return count
    }

    @MainActor
    private func runningSnapshot(runID: UUID) -> AgentRunSnapshot {
        AgentRunSnapshot(
            runID: runID,
            profileID: UUID(),
            accent: .purple,
            prompt: "Question",
            providerName: "Codex",
            phase: .running,
            voiceInput: "",
            output: "",
            timeline: [],
            diagnostics: "",
            plan: [],
            tools: [],
            permissions: [],
            notices: [],
            elapsedSeconds: 0,
            evictedToolCount: 0,
            ignoredToolUpdateCount: 0)
    }

    @MainActor
    private func replacingPhase(
        _ phase: AgentRunPhase,
        in snapshot: AgentRunSnapshot
    ) -> AgentRunSnapshot {
        AgentRunSnapshot(
            runID: snapshot.runID,
            profileID: snapshot.profileID,
            accent: snapshot.accent,
            prompt: snapshot.prompt,
            providerName: snapshot.providerName,
            phase: phase,
            voiceInput: snapshot.voiceInput,
            output: snapshot.output,
            timeline: snapshot.timeline,
            diagnostics: snapshot.diagnostics,
            plan: snapshot.plan,
            tools: snapshot.tools,
            permissions: snapshot.permissions,
            notices: snapshot.notices,
            elapsedSeconds: snapshot.elapsedSeconds,
            evictedToolCount: snapshot.evictedToolCount,
            ignoredToolUpdateCount: snapshot.ignoredToolUpdateCount)
    }
}

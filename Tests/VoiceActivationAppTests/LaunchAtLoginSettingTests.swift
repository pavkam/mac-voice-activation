// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import VoiceActivationApp

private actor FakeLaunchAtLoginService: LaunchAtLoginServicing {
    private var storedIsEnabled: Bool
    private var readCount = 0
    private var requestedValues: [Bool] = []
    private var rejectsChanges = false

    func isEnabled() -> Bool {
        readCount += 1
        return storedIsEnabled
    }

    init(isEnabled: Bool) {
        storedIsEnabled = isEnabled
    }

    func setEnabled(_ enabled: Bool) throws {
        requestedValues.append(enabled)
        if rejectsChanges {
            throw FakeLaunchAtLoginError.rejected
        }
        storedIsEnabled = enabled
    }

    func snapshot() -> (readCount: Int, requestedValues: [Bool]) {
        (readCount, requestedValues)
    }

    func rejectChanges() {
        rejectsChanges = true
    }
}

private actor SuspendedLaunchAtLoginService: LaunchAtLoginServicing {
    private var completedValue: Bool?
    private var continuations: [CheckedContinuation<Bool, Never>] = []
    private var readCount = 0

    func isEnabled() async -> Bool {
        readCount += 1
        if let completedValue {
            return completedValue
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func setEnabled(_: Bool) {}

    func waitUntilReadStarts() async {
        while readCount == 0 {
            await Task.yield()
        }
    }

    func complete(with enabled: Bool) {
        completedValue = enabled
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: enabled)
        }
    }

    func reads() -> Int {
        readCount
    }
}

private enum FakeLaunchAtLoginError: Error, LocalizedError {
    case rejected

    var errorDescription: String? {
        "macOS rejected the login item."
    }
}

struct LaunchAtLoginSettingTests {
    @MainActor
    @Test
    func state_WhenInitialized_DoesNotSynchronouslyReadSystemRegistration() async {
        let service = FakeLaunchAtLoginService(isEnabled: true)

        _ = LaunchAtLoginSetting(service: service)

        let snapshot = await service.snapshot()
        #expect(snapshot.readCount == 0)
    }

    @MainActor
    @Test
    func refresh_WhenCalled_ReflectsSystemRegistration() async {
        let service = FakeLaunchAtLoginService(isEnabled: true)
        let setting = LaunchAtLoginSetting(service: service)

        await setting.refresh()

        #expect(setting.isEnabled)
        #expect(!setting.isBusy)
        #expect(setting.errorMessage == nil)
        let snapshot = await service.snapshot()
        #expect(snapshot.readCount == 1)
    }

    @MainActor
    @Test
    func refresh_WhenAnotherOperationIsRunning_DoesNotStartOverlappingSystemWork() async {
        let service = SuspendedLaunchAtLoginService()
        let setting = LaunchAtLoginSetting(service: service)
        let firstRefresh = Task { @MainActor in await setting.refresh() }
        await service.waitUntilReadStarts()

        let overlappingRefresh = Task { @MainActor in await setting.refresh() }
        for _ in 0..<10 {
            await Task.yield()
        }

        let readCount = await service.reads()
        #expect(readCount == 1)
        await service.complete(with: true)
        await firstRefresh.value
        await overlappingRefresh.value
        #expect(setting.isEnabled)
        #expect(!setting.isBusy)
    }

    @MainActor
    @Test
    func setEnabled_WhenRegistrationSucceeds_UpdatesSystemAndVisibleState() async {
        let service = FakeLaunchAtLoginService(isEnabled: false)
        let setting = LaunchAtLoginSetting(service: service)

        await setting.setEnabled(true)

        let snapshot = await service.snapshot()
        #expect(snapshot.requestedValues == [true])
        #expect(setting.isEnabled)
        #expect(!setting.isBusy)
        #expect(setting.errorMessage == nil)
    }

    @MainActor
    @Test
    func setEnabled_WhenRegistrationFails_RestoresSystemStateAndShowsError() async {
        let service = FakeLaunchAtLoginService(isEnabled: false)
        await service.rejectChanges()
        let setting = LaunchAtLoginSetting(service: service)

        await setting.setEnabled(true)

        let snapshot = await service.snapshot()
        #expect(snapshot.requestedValues == [true])
        #expect(!setting.isEnabled)
        #expect(!setting.isBusy)
        #expect(setting.errorMessage == "macOS rejected the login item.")
    }

    @MainActor
    @Test
    func setEnabled_WhenRegistrationCompletes_RecordsRequestAndObservedResult() async {
        let service = FakeLaunchAtLoginService(isEnabled: false)
        let diagnostics = AppDiagnosticRecorderSpy()
        let setting = LaunchAtLoginSetting(service: service, diagnostics: diagnostics)

        await setting.setEnabled(true)

        let entries = diagnostics.snapshot()
        #expect(
            entries.map(\.event) == [
                "launch_at_login.initialized",
                "launch_at_login.change_requested",
                "launch_at_login.change_finished",
            ])
        #expect(entries.last?.fields["requested_enabled"] == "true")
        #expect(entries.last?.fields["observed_enabled"] == "true")
    }
}

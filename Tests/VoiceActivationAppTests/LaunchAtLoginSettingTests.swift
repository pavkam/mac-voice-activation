import Foundation
import Testing
@testable import VoiceActivationApp

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var isEnabled: Bool
    var requestedValues: [Bool] = []
    var failure: Error?

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    func setEnabled(_ enabled: Bool) throws {
        requestedValues.append(enabled)
        if let failure {
            throw failure
        }
        isEnabled = enabled
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
    func state_WhenInitialized_ReflectsSystemRegistration() {
        let service = FakeLaunchAtLoginService(isEnabled: true)

        let setting = LaunchAtLoginSetting(service: service)

        #expect(setting.isEnabled)
        #expect(setting.errorMessage == nil)
    }

    @MainActor
    @Test
    func setEnabled_WhenRegistrationSucceeds_UpdatesSystemAndVisibleState() {
        let service = FakeLaunchAtLoginService(isEnabled: false)
        let setting = LaunchAtLoginSetting(service: service)

        setting.setEnabled(true)

        #expect(service.requestedValues == [true])
        #expect(setting.isEnabled)
        #expect(setting.errorMessage == nil)
    }

    @MainActor
    @Test
    func setEnabled_WhenRegistrationFails_RestoresSystemStateAndShowsError() {
        let service = FakeLaunchAtLoginService(isEnabled: false)
        service.failure = FakeLaunchAtLoginError.rejected
        let setting = LaunchAtLoginSetting(service: service)

        setting.setEnabled(true)

        #expect(service.requestedValues == [true])
        #expect(!setting.isEnabled)
        #expect(setting.errorMessage == "macOS rejected the login item.")
    }
}

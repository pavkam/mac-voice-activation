// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AVFoundation
import AppKit
import Foundation
import Testing
@testable import VoiceActivationApp

struct AudioEngineConfigurationMonitorTests {
    @MainActor @Test
    func configurationChange_WhenAppKitTracksEvents_NotifiesWithoutWaitingForDefaultMode() {
        let notificationCenter = NotificationCenter()
        let monitor = AudioEngineConfigurationMonitor(notificationCenter: notificationCenter)
        let engine = AVAudioEngine()
        var changeCount = 0
        monitor.start(observing: engine) {
            changeCount += 1
        }

        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)
        runAudioMonitorEventTrackingLoop {
            changeCount == 0
        }
        monitor.stop()

        #expect(changeCount == 1)
    }

    @MainActor @Test func configurationChange_WhenObservedEngineChanges_NotifiesClient() async {
        let notificationCenter = NotificationCenter()
        let monitor = AudioEngineConfigurationMonitor(notificationCenter: notificationCenter)
        let engine = AVAudioEngine()
        var changeCount = 0
        monitor.start(observing: engine) {
            changeCount += 1
        }

        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)
        await Task.yield()

        #expect(changeCount == 1)
    }

    @MainActor @Test func configurationChange_WhenAnotherEngineChanges_IgnoresNotification() async {
        let notificationCenter = NotificationCenter()
        let monitor = AudioEngineConfigurationMonitor(notificationCenter: notificationCenter)
        let observedEngine = AVAudioEngine()
        var changeCount = 0
        monitor.start(observing: observedEngine) {
            changeCount += 1
        }

        notificationCenter.post(
            name: .AVAudioEngineConfigurationChange,
            object: AVAudioEngine())
        await Task.yield()

        #expect(changeCount == 0)
    }

    @MainActor @Test func stop_WhenEngineChanges_DoesNotNotifyClient() async {
        let notificationCenter = NotificationCenter()
        let monitor = AudioEngineConfigurationMonitor(notificationCenter: notificationCenter)
        let engine = AVAudioEngine()
        var changeCount = 0
        monitor.start(observing: engine) {
            changeCount += 1
        }
        monitor.stop()

        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)
        await Task.yield()

        #expect(changeCount == 0)
    }
}

@MainActor
private func runAudioMonitorEventTrackingLoop(while condition: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 0.25)
    while condition(), Date() < deadline {
        _ = RunLoop.main.run(
            mode: .eventTracking,
            before: min(deadline, Date(timeIntervalSinceNow: 0.01)))
    }
}

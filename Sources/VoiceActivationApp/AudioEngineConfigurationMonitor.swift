// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation

@MainActor
final class AudioEngineConfigurationMonitor {
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func start(
        observing engine: AVAudioEngine,
        onChange: @escaping @MainActor @Sendable () -> Void)
    {
        stop()
        observer = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil)
        { _ in
            Task { @MainActor in
                onChange()
            }
        }
    }

    func stop() {
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }
}

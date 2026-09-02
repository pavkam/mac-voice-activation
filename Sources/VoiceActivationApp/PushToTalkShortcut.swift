import Carbon.HIToolbox
import Foundation
import VoiceActivationCore

@MainActor
protocol PushToTalkShortcutManaging: AnyObject {
    func start(
        hotKey: PushToTalkHotKey,
        onPressed: @escaping () -> Void,
        onReleased: @escaping () -> Void) throws

    func stop()
}

@MainActor
final class PushToTalkShortcut: PushToTalkShortcutManaging {
    enum RegistrationError: Error, LocalizedError {
        case eventHandler(OSStatus)
        case hotKey(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .eventHandler(status):
                "Could not prepare the push-to-talk shortcut (error \(status))."
            case let .hotKey(status):
                "That shortcut is unavailable. Choose another combination (error \(status))."
            }
        }
    }

    private static let signature: OSType = 0x56414354

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var onPressed: (() -> Void)?
    private var onReleased: (() -> Void)?

    func start(
        hotKey configuration: PushToTalkHotKey,
        onPressed: @escaping () -> Void,
        onReleased: @escaping () -> Void) throws
    {
        stop()
        self.onPressed = onPressed
        self.onReleased = onReleased

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let owner = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let shortcut = Unmanaged<PushToTalkShortcut>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                let kind = GetEventKind(event)
                MainActor.assumeIsolated {
                    if kind == UInt32(kEventHotKeyPressed) {
                        shortcut.onPressed?()
                    } else if kind == UInt32(kEventHotKeyReleased) {
                        shortcut.onReleased?()
                    }
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            owner,
            &eventHandler)
        guard handlerStatus == noErr else {
            stop()
            throw RegistrationError.eventHandler(handlerStatus)
        }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let registrationStatus = RegisterEventHotKey(
            configuration.keyCode,
            Self.carbonModifiers(for: configuration.modifiers),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey)
        guard registrationStatus == noErr else {
            stop()
            throw RegistrationError.hotKey(registrationStatus)
        }
    }

    func stop() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        hotKey = nil
        eventHandler = nil
        onPressed = nil
        onReleased = nil
    }

    static func carbonModifiers(for modifiers: HotKeyModifiers) -> UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }
}

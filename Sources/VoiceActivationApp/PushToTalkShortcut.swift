import Carbon.HIToolbox
import Foundation

@MainActor
final class PushToTalkShortcut {
    private static let signature: OSType = 0x56414354

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var onPressed: (() -> Void)?
    private var onReleased: (() -> Void)?

    func start(onPressed: @escaping () -> Void, onReleased: @escaping () -> Void) {
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
        InstallEventHandler(
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

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey)
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
}

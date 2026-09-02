import Carbon.HIToolbox
import Foundation
import VoiceActivationCore

@MainActor
protocol PushToTalkShortcutManaging: AnyObject {
    func start(
        profiles: [WakeProfile],
        onPressed: @escaping (UUID) -> Void,
        onReleased: @escaping (UUID) -> Void) throws

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
    private var hotKeys: [EventHotKeyRef] = []
    private var profileIDs: [UInt32: UUID] = [:]
    private var onPressed: ((UUID) -> Void)?
    private var onReleased: ((UUID) -> Void)?

    func start(
        profiles: [WakeProfile],
        onPressed: @escaping (UUID) -> Void,
        onReleased: @escaping (UUID) -> Void) throws
    {
        stop()
        self.onPressed = onPressed
        self.onReleased = onReleased
        let bindings = profiles.compactMap { profile in
            profile.pushToTalkHotKey.map { (profile.id, $0) }
        }
        guard !bindings.isEmpty else { return }

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
                var identifier = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier)
                guard
                    parameterStatus == noErr,
                    let profileID = shortcut.profileIDs[identifier.id]
                else { return OSStatus(eventNotHandledErr) }
                let kind = GetEventKind(event)
                MainActor.assumeIsolated {
                    if kind == UInt32(kEventHotKeyPressed) {
                        shortcut.onPressed?(profileID)
                    } else if kind == UInt32(kEventHotKeyReleased) {
                        shortcut.onReleased?(profileID)
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

        for (index, binding) in bindings.enumerated() {
            let identifierValue = UInt32(index + 1)
            let identifier = EventHotKeyID(signature: Self.signature, id: identifierValue)
            var registeredHotKey: EventHotKeyRef?
            let registrationStatus = RegisterEventHotKey(
                binding.1.keyCode,
                Self.carbonModifiers(for: binding.1.modifiers),
                identifier,
                GetApplicationEventTarget(),
                0,
                &registeredHotKey)
            guard registrationStatus == noErr, let registeredHotKey else {
                stop()
                throw RegistrationError.hotKey(registrationStatus)
            }
            hotKeys.append(registeredHotKey)
            profileIDs[identifierValue] = binding.0
        }
    }

    func stop() {
        for hotKey in hotKeys {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        hotKeys = []
        profileIDs = [:]
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

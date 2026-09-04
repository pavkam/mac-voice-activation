// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

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
        case duplicateHotKey

        var errorDescription: String? {
            switch self {
            case .eventHandler(let status):
                "Could not prepare the push-to-talk shortcut (error \(status))."
            case .hotKey(let status):
                "That shortcut is unavailable. Choose another combination (error \(status))."
            case .duplicateHotKey:
                "Push-to-talk shortcuts must be unique."
            }
        }
    }

    private struct PhysicalHotKeyIdentity: Hashable {
        let keyCode: UInt32
        let modifiers: HotKeyModifiers

        init(_ hotKey: PushToTalkHotKey) {
            keyCode = hotKey.keyCode
            modifiers = hotKey.modifiers
        }
    }

    struct RegistrationBackend {
        let installEventHandler: (PushToTalkShortcut) throws -> EventHandlerRef
        let removeEventHandler: (EventHandlerRef) -> Void
        let registerHotKey: (PushToTalkHotKey, EventHotKeyID) throws -> EventHotKeyRef
        let unregisterHotKey: (EventHotKeyRef) -> Void

        @MainActor static let live = RegistrationBackend(
            installEventHandler: { try $0.installLiveEventHandler() },
            removeEventHandler: { RemoveEventHandler($0) },
            registerHotKey: { hotKey, identifier in
                var registeredHotKey: EventHotKeyRef?
                let status = RegisterEventHotKey(
                    hotKey.keyCode,
                    PushToTalkShortcut.carbonModifiers(for: hotKey.modifiers),
                    identifier,
                    GetApplicationEventTarget(),
                    0,
                    &registeredHotKey)
                guard status == noErr, let registeredHotKey else {
                    throw RegistrationError.hotKey(status)
                }
                return registeredHotKey
            },
            unregisterHotKey: { UnregisterEventHotKey($0) })
    }

    private static let signature: OSType = 0x5641_4354

    private var eventHandler: EventHandlerRef?
    private var hotKeys:
        [(
            hotKey: PushToTalkHotKey,
            reference: EventHotKeyRef,
            identifier: UInt32,
        )] = []
    private var profileIDs: [UInt32: UUID] = [:]
    private var onPressed: ((UUID) -> Void)?
    private var onReleased: ((UUID) -> Void)?
    private var nextIdentifier: UInt32 = 1
    private let registrationBackend: RegistrationBackend
    private let diagnostics: any VoiceActivationDiagnosticRecording

    init(
        registrationBackend: RegistrationBackend = .live,
        diagnostics: any VoiceActivationDiagnosticRecording = VoiceActivationDiagnostics.shared
    ) {
        self.registrationBackend = registrationBackend
        self.diagnostics = diagnostics
    }

    func start(
        profiles: [WakeProfile],
        onPressed: @escaping (UUID) -> Void,
        onReleased: @escaping (UUID) -> Void
    ) throws {
        let bindings = profiles.compactMap { profile in
            profile.pushToTalkHotKey.map { (profile.id, $0) }
        }
        diagnostics.record(
            category: .hotKey,
            event: "hot_key.registration_started",
            fields: [
                "profile_count": String(profiles.count),
                "binding_count": String(bindings.count),
            ])
        let identities = bindings.map { PhysicalHotKeyIdentity($0.1) }
        guard Set(identities).count == identities.count else {
            diagnostics.record(
                category: .hotKey,
                event: "hot_key.registration_failed",
                level: .error,
                fields: ["reason": "duplicate_binding"])
            throw RegistrationError.duplicateHotKey
        }

        var installedHandler = false
        if !bindings.isEmpty, eventHandler == nil {
            eventHandler = try registrationBackend.installEventHandler(self)
            installedHandler = true
        }

        var candidateHotKeys:
            [(
                hotKey: PushToTalkHotKey,
                reference: EventHotKeyRef,
                identifier: UInt32,
                profileID: UUID,
            )] = []
        var newReferences: [EventHotKeyRef] = []
        for binding in bindings {
            if let existing = hotKeys.first(where: {
                $0.hotKey.keyCode == binding.1.keyCode
                    && $0.hotKey.modifiers == binding.1.modifiers
            }) {
                candidateHotKeys.append(
                    (
                        hotKey: binding.1,
                        reference: existing.reference,
                        identifier: existing.identifier,
                        profileID: binding.0
                    ))
                continue
            }

            let identifierValue = nextIdentifier
            nextIdentifier &+= 1
            let identifier = EventHotKeyID(signature: Self.signature, id: identifierValue)
            let registeredHotKey: EventHotKeyRef
            do {
                registeredHotKey = try registrationBackend.registerHotKey(binding.1, identifier)
            } catch {
                for reference in newReferences {
                    registrationBackend.unregisterHotKey(reference)
                }
                if installedHandler, let eventHandler {
                    registrationBackend.removeEventHandler(eventHandler)
                    self.eventHandler = nil
                }
                diagnostics.record(
                    category: .hotKey,
                    event: "hot_key.registration_failed",
                    level: .error,
                    fields: [
                        "reason": "backend_error",
                        "error_type": String(describing: type(of: error)),
                    ])
                throw error
            }
            newReferences.append(registeredHotKey)
            candidateHotKeys.append(
                (
                    hotKey: binding.1,
                    reference: registeredHotKey,
                    identifier: identifierValue,
                    profileID: binding.0
                ))
        }

        let retainedIdentifiers = Set(candidateHotKeys.map(\.identifier))
        for hotKey in hotKeys where !retainedIdentifiers.contains(hotKey.identifier) {
            registrationBackend.unregisterHotKey(hotKey.reference)
        }
        hotKeys = candidateHotKeys.map {
            (hotKey: $0.hotKey, reference: $0.reference, identifier: $0.identifier)
        }
        profileIDs = Dictionary(
            uniqueKeysWithValues: candidateHotKeys.map {
                ($0.identifier, $0.profileID)
            })
        self.onPressed = bindings.isEmpty ? nil : onPressed
        self.onReleased = bindings.isEmpty ? nil : onReleased

        if bindings.isEmpty, let eventHandler {
            registrationBackend.removeEventHandler(eventHandler)
            self.eventHandler = nil
        }
        diagnostics.record(
            category: .hotKey,
            event: "hot_key.registration_finished",
            fields: [
                "binding_count": String(bindings.count),
                "registered_count": String(hotKeys.count),
                "has_event_handler": String(eventHandler != nil),
            ])
    }

    func stop() {
        let unregisteredCount = hotKeys.count
        for hotKey in hotKeys {
            registrationBackend.unregisterHotKey(hotKey.reference)
        }
        if let eventHandler {
            registrationBackend.removeEventHandler(eventHandler)
        }
        hotKeys = []
        profileIDs = [:]
        eventHandler = nil
        onPressed = nil
        onReleased = nil
        diagnostics.record(
            category: .hotKey,
            event: "hot_key.registration_stopped",
            fields: ["unregistered_count": String(unregisteredCount)])
    }

    private func installLiveEventHandler() throws -> EventHandlerRef {
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let owner = Unmanaged.passUnretained(self).toOpaque()
        var installedEventHandler: EventHandlerRef?
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
                        shortcut.diagnostics.record(
                            category: .hotKey,
                            event: "hot_key.pressed",
                            fields: ["profile_id": profileID.uuidString])
                        shortcut.onPressed?(profileID)
                    } else if kind == UInt32(kEventHotKeyReleased) {
                        shortcut.diagnostics.record(
                            category: .hotKey,
                            event: "hot_key.released",
                            fields: ["profile_id": profileID.uuidString])
                        shortcut.onReleased?(profileID)
                    }
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            owner,
            &installedEventHandler)
        guard handlerStatus == noErr, let installedEventHandler else {
            throw RegistrationError.eventHandler(handlerStatus)
        }
        return installedEventHandler
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

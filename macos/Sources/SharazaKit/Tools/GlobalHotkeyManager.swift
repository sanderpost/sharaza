import Carbon
import Foundation

/// Global hotkey service using Carbon `RegisterEventHotKey` (`HIToolbox`), verified from
/// `XerahS.Platform.MacOS.Native.CarbonHotkeys`: registers global shortcuts cleanly without
/// requiring macOS Accessibility TCC permissions.
@MainActor
public final class GlobalHotkeyManager {
    public static let shared = GlobalHotkeyManager()

    private let hotKeySignature: OSType = 0x5348525A // 'SHRZ'
    private var eventHandlerRef: EventHandlerRef?
    private var registeredRefs: [UInt32: EventHotKeyRef] = [:]
    private var actionsByID: [UInt32: String] = [:]
    public var onHotkeyTriggered: ((String) -> Void)?

    private init() {}

    public func installAndApply(bindings: [HotkeyBinding], globallyEnabled: Bool) {
        unregisterAll()
        guard globallyEnabled else { return }
        ensureEventHandlerInstalled()

        var nextID: UInt32 = 1
        for binding in bindings where binding.enabled {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: hotKeySignature, id: nextID)
            let status = RegisterEventHotKey(
                binding.key_code,
                binding.modifiers,
                hkID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                registeredRefs[nextID] = ref
                actionsByID[nextID] = binding.action
            }
            nextID += 1
        }
    }

    public func unregisterAll() {
        for (_, ref) in registeredRefs {
            UnregisterEventHotKey(ref)
        }
        registeredRefs.removeAll()
        actionsByID.removeAll()
    }

    private func ensureEventHandlerInstalled() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
            guard let eventRef else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            if status == noErr {
                let id = hkID.id
                Task { @MainActor in
                    GlobalHotkeyManager.shared.handleHotKeyID(id)
                }
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }

    private func handleHotKeyID(_ id: UInt32) {
        guard let action = actionsByID[id] else { return }
        onHotkeyTriggered?(action)
    }
}

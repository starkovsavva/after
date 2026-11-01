import AfterPlatform
import Carbon
import Foundation

/// Carbon registration is owned by this token. No Accessibility permission or
/// UI controller pointer is passed through the native callback.
@MainActor
package final class MacOSGlobalShortcuts: GlobalShortcutRegistering {
    private var keys: [GlobalShortcutAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var handler: (@MainActor (GlobalShortcutAction) -> Void)?
    private var generation = UUID()
    package init() {}

    package func start(handler: @escaping @MainActor (GlobalShortcutAction) -> Void) -> Bool {
        stop()
        self.handler = handler
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr else { return result }
            guard key.signature == 0x50534C45, let action = GlobalShortcutAction(rawValue: key.id) else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<MacOSGlobalShortcuts>.fromOpaque(data).takeUnretainedValue()
            // Carbon delivers on the application event target (main thread).
            MainActor.assumeIsolated {
                let token = owner.generation
                Task { @MainActor [weak owner] in
                    guard let owner, owner.generation == token, owner.keys[action] != nil else { return }
                    owner.handler?(action)
                }
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if status != noErr { stop(); return false }
        return true
    }

    package func configure(_ bindings: [GlobalShortcutBinding]) -> Set<GlobalShortcutAction> {
        unregisterKeys()
        generation = UUID()
        guard eventHandler != nil else { return Set(bindings.map(\.action)) }
        var failed: Set<GlobalShortcutAction> = []
        for binding in bindings {
            let code: UInt32, modifiers: UInt32
            switch binding.key {
            case .controlOptionN: code = UInt32(kVK_ANSI_N); modifiers = UInt32(controlKey | optionKey)
            case .controlShiftSpace: code = UInt32(kVK_Space); modifiers = UInt32(controlKey | shiftKey)
            case .controlOptionB: code = UInt32(kVK_ANSI_B); modifiers = UInt32(controlKey | optionKey)
            case .controlOptionM: code = UInt32(kVK_ANSI_M); modifiers = UInt32(controlKey | optionKey)
            }
            var key: EventHotKeyRef?
            let status = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x50534C45, id: binding.action.rawValue),
                GetApplicationEventTarget(), 0, &key)
            if status == noErr, let key { keys[binding.action] = key }
            else { failed.insert(binding.action) }
        }
        return failed
    }

    package func stop() {
        generation = UUID(); unregisterKeys()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil; handler = nil
    }
    private func unregisterKeys() {
        for key in keys.values { UnregisterEventHotKey(key) }
        keys.removeAll()
    }
    deinit {
        for key in keys.values { UnregisterEventHotKey(key) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
